--- OllamaClient.lua — Communicate with a local Ollama server.
--- Handles base URL construction, model discovery, HTTP requests to the generate API,
--- and orchestrates the full pipeline: export thumbnail -> encode -> build prompt -> POST
--- -> validate response.
--- SDK imports: LrHttp, LrPrefs, LrLogger, LrPathUtils, LrTasks

local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local LrLogger = import 'LrLogger'
local LrTasks = import "LrTasks"
local LrPrefs = import "LrPrefs"

local logger = LrLogger('LrLlama')
logger:enable("logfile") -- Logs to ~/Documents/LrClassicLogs | tail -f LrLlama.log

-- Load shared utilities
local JSON = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "JSON.lua"))))()
local ThumbnailService = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "ThumbnailService.lua"))))()
local PromptBuilder = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "PromptBuilder.lua"))))()
local ResponseValidator = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "ResponseValidator.lua"))))()

--------------------------------------------------------------------------------
--- Helpers for exception-safe cleanup
--------------------------------------------------------------------------------

--- Run *operation*, then always attempt *cleanupFn*.
--- Does NOT use pcall — Lightroom's LrTasks.startAsyncTask already runs
--- in a protected context, and nesting pcall inside that context prevents
--- SDK functions (http.post, encodeBase64, etc.) from yielding to the
--- Lightroom event loop, causing "Yielding is not allowed" errors.
--- Cleanup always runs after the operation so the temp thumbnail is removed
--- before validation or error propagation.
---@param thumbnailPath string  Path to delete after operation
---@param operation function    Generation logic returning (result, error)
---@param cleanupFn function   Cleanup function accepting the path
---@return ... The return values of *operation*
local function runWithCleanup(thumbnailPath, operation, cleanupFn)
    local result, err = operation()
    cleanupFn(thumbnailPath)
    return result, err
end

--------------------------------------------------------------------------------
--- Constructor — create a client with injectable dependencies.
--- callers need no changes while tests can provide lightweight fakes.
---@param deps table|nil Optional dependency overrides:
---   { http, prefs, tasks, json, thumbnailService, promptBuilder, responseValidator, logger }
---@return table client Fully initialised OllamaClient instance
--------------------------------------------------------------------------------
local function createClient(deps)
    deps = deps or {}

    local http = deps.http or LrHttp
    local prefsService = deps.prefs or LrPrefs
    local tasks = deps.tasks or LrTasks
    local json = deps.json or JSON
    local thumbnailService = deps.thumbnailService or ThumbnailService
    local promptBuilder = deps.promptBuilder or PromptBuilder
    local responseValidator = deps.responseValidator or ResponseValidator
    local activeLogger = deps.logger or logger

    local client = {}

    --------------------------------------------------------------------------------
    -- Constants
    --------------------------------------------------------------------------------

    --- Default Ollama model name; change here to switch models.
    client.defaultModel = "gemma4:latest"

    --- Fallback server address when prefs are missing, empty, or invalid.
    client.defaultServerHost = "localhost:11434"

    --------------------------------------------------------------------------------
    -- Server configuration
    --------------------------------------------------------------------------------

    --- Validate and normalize an Ollama server address.
    --- Strips optional scheme (`http://`) and trailing slashes, then verifies the
    --- string is `hostname:port`. Accepts localhost, IP addresses, and domain names.
   ---@param input string|nil User-supplied server address (may be empty)
   ---@return bool ok    True when the address is valid
   ---@return string result The normalized host:port on success, error message on failure
    function client.validateServerHost(input)
        if not input or input == "" then
            return true, client.defaultServerHost  -- treat empty as "use default"
        end
        -- Strip scheme and trailing slashes for normalization
        local host = string.gsub(input, "^https?://", "")
        host = string.gsub(host, "/+$", "")

        -- Must match something:digit (hostname or IP followed by colon and port)
        local hostnamePart, portPart = string.match(host, "^([^:]+):(%d+)$")
        if not hostnamePart or not portPart then
            return false, "Server address must be in host:port format (e.g., localhost:11434)"
        end

        local port = tonumber(portPart)
        if port < 1 or port > 65535 then
            return false, "Port number must be between 1 and 65535"
        end

        -- hostnamePart should contain at least one valid character (alphanumeric, dot, hyphen)
        if not string.match(hostnamePart, "^[%a%d%.%-]+$") then
            return false, "Hostname contains invalid characters"
        end

        return true, hostnamePart .. ":" .. portPart
    end

    --- Build the base URL from saved preferences.
    --- Reads prefs.ollamaServerHost, validates, falls back to default if malformed.
   ---@param prefs table LrPrefs.prefsForPlugin() instance (injected for testability)
   ---@return string baseUrl Full URL like "http://localhost:11434"
    function client.getBaseUrl(prefs)
        local ok, host = client.validateServerHost(prefs.ollamaServerHost)

        if not ok then
            activeLogger:warn("Invalid server host in prefs: " .. tostring(prefs.ollamaServerHost))
            host = client.defaultServerHost
        end

        return "http://" .. host
    end

    --------------------------------------------------------------------------------
    -- Model discovery
    --------------------------------------------------------------------------------

    --- Convert a plain list of model names into the `{title, value}` format that
    --- LrView `popup_menu` requires for its `items` binding.
   ---@param modelNames table<string> List of model strings (from fetchModels)
   ---@return table<table> Table of `{title = m, value = m}` entries for popup_menu binding
    function client.makeModelItems(modelNames)
        local items = {}
        for _, m in ipairs(modelNames) do
            table.insert(items, { title = m, value = m })
        end
        return items
    end

    --- Query Ollama's `/api/tags` endpoint for installed models.
    --- Falls back to `{defaultModel}` on network errors, malformed JSON, or an empty
    --- model list — so callers never receive nil.
   ---@param prefs table LrPrefs instance
   ---@return table<string> List of model name strings; always non-empty.
    function client.fetchModels(prefs)
        activeLogger:info("Fetching available models from Ollama")

        local url = client.getBaseUrl(prefs) .. "/api/tags"
        local response = http.get(url)

        if response then
            local decodeSuccess, data = pcall(function()
                return json:decode(response)
            end)

            if decodeSuccess and data and type(data.models) == "table" then
                local modelList = {}

                for _, availableModel in ipairs(data.models) do
                    local modelName = availableModel.name or availableModel.model

                    if modelName and modelName ~= "" then
                        table.insert(modelList, modelName)
                    end
                end

                if #modelList > 0 then
                    activeLogger:info("Found " .. #modelList .. " models")
                    return modelList
                end

                activeLogger:warn("Ollama returned an empty model list")
            elseif not decodeSuccess then
                activeLogger:warn(
                    "Failed to decode Ollama model response: " .. tostring(data)
                )
            else
                activeLogger:warn("Ollama response did not contain a valid model list")
            end
        else
            activeLogger:warn("No response received from Ollama")
        end

        activeLogger:warn("Using default model: " .. client.defaultModel)
        return { client.defaultModel }
    end

    --- Persist the server host and rebuild the model dropdown.
    --- MUST be called from within `LrTasks.startAsyncTask()` — LrBinding only
    --- propagates property reassignments (modelItems, selectedModel) when done
    --- off the UI thread.
   ---@param props table LrBinding property table containing serverHost, modelItems, selectedModel
   ---@param prefs table LrPrefs.prefsForPlugin() instance
   ---@return bool ok True on success
   ---@return string message Human-readable status or error description
    function client.saveServerAndRefresh(props, prefs)
        local ok, validatedHost = client.validateServerHost(props.serverHost)
        if not ok then
            return false, validatedHost  -- caller displays error
        end

        prefs.ollamaServerHost = validatedHost

        local availableModels = client.fetchModels(prefs)
        if not availableModels or #availableModels == 0 then
            return false, "No models found on server"
        end

        -- Rebuild model list. This function is intended to be called from inside
        -- LrTasks.startAsyncTask() so that LrBinding picks up the property
        -- reassignment and propagates it to the dialog's popup_menu.
        local oldSelection = props.selectedModel or ""
        props.modelItems = client.makeModelItems(availableModels)

        -- Keep old selection if it still exists in the new list
        local found = false
        for _, m in ipairs(availableModels) do
            if m == oldSelection then found = true; break; end
        end
        props.selectedModel = found and oldSelection or availableModels[1]

        return true, string.format("Loaded %d model(s)", #availableModels)
    end

    --------------------------------------------------------------------------------
    -- Generate pipeline
    --------------------------------------------------------------------------------

    --- Export thumbnail with retry logic (up to 3 attempts, 500ms between failures).
    ---@param photo LrPhoto Photo object from the catalog
    ---@return string|nil Path on success, nil after all retries exhausted
    local function exportWithRetries(photo)
        for attempt = 1, 3 do
            local path = thumbnailService.export(photo)
            if path then
                return path
            end
            activeLogger:warn("Thumbnail export attempt " .. attempt .. " failed, retrying...")
            tasks.sleep(0.5) -- Wait 500ms before retry
        end
        return nil
    end

    --- Execute the HTTP POST step: encode, build prompt, assemble body, send request.
    --- Returns the raw HTTP response string (or nil on failure). Cleanup is NOT
    --- performed here — it is the responsibility of `runWithCleanup`.
    ---@param thumbnailPath string Path to exported JPEG
    ---@param userInstruction string User-facing prompt text
    ---@param currentData table|nil Existing title/caption
    ---@param useCurrentData boolean Include current metadata in prompt
    ---@param useSystemPrompt boolean Send system prompt
    ---@param selectedModel string|nil Model name
    ---@param systemPromptOverride string|nil Custom system prompt
    ---@return string|nil rawResponse HTTP response body, or nil
    ---@return string|nil err Error message
    local function executePost(thumbnailPath, userInstruction, currentData,
                               useCurrentData, useSystemPrompt, selectedModel,
                               systemPromptOverride)
        -- Encode image as Base64
        local encodedImage = thumbnailService.encodeBase64(thumbnailPath)
        if not encodedImage then
            return nil, "Failed to encode image"
        end

        -- Build user prompt and request body
        local builtPrompt = promptBuilder.buildUserPrompt(userInstruction, currentData, useCurrentData)
        local requestBody = promptBuilder.assembleRequestBody(
            builtPrompt, selectedModel or client.defaultModel,
            useSystemPrompt, systemPromptOverride
        )
        requestBody.images = {encodedImage}

        -- Send HTTP POST
        local url = client.getBaseUrl(prefsService.prefsForPlugin()) .. "/api/generate"
        local jsonPayload = json:encode(requestBody)

        local response = http.post(url, jsonPayload, {{
            field = "Content-Type",
            value = "application/json"
        }})

        if not response then
            return nil, "Failed to send data to the API"
        end

        -- Return raw response for validation (after cleanup in caller).
        return response, nil
    end

    --- High-level generate: export thumbnail, encode, build prompt, POST, validate response.
    --- Orchestrates ThumbnailService + PromptBuilder + ResponseValidator internally.
    --- This is the decomposition of the former Common.sendDataToApi mega-function.
    --- Retries thumbnail export up to 3 times. Cleans up the temp file after the
    --- HTTP request regardless of success or failure (even when downstream code throws).
    --- Validation runs after cleanup so the thumbnail is always removed first.
   ---@param photo LrPhoto Photo object from the catalog
   ---@param userInstruction string User-facing prompt text
   ---@param currentData table|nil Existing title/caption to prepend when useCurrentData is true
   ---@param useCurrentData boolean Whether to include current metadata in the prompt
   ---@param useSystemPrompt boolean Whether to send a system prompt alongside the user prompt
   ---@param selectedModel string|nil Model name; falls back to the default if nil
   ---@param systemPromptOverride string|nil Override for the built-in system prompt
   ---@return table|nil response Parsed JSON on success ({title, caption, keywords})
   ---@return string|nil err Error message, or nil on success
    function client.generate(photo, userInstruction, currentData, useCurrentData,
                             useSystemPrompt, selectedModel, systemPromptOverride)
        activeLogger:info("Sending data to API")

        -- Export thumbnail with retry; early return avoids cleanup when nothing created.
        local thumbnailPath = exportWithRetries(photo)
        if not thumbnailPath then
            return nil, "Failed to export thumbnail after 3 attempts"
        end

        -- Run the HTTP POST under exception-safe cleanup: thumbnail is deleted after
        -- the request regardless of success or exception.
        local rawResponse, err = runWithCleanup(
            thumbnailPath,
            function()
                return executePost(thumbnailPath, userInstruction, currentData,
                                   useCurrentData, useSystemPrompt, selectedModel,
                                   systemPromptOverride)
            end,
            function(path) thumbnailService.cleanup(path) end
        )

        -- If POST/cleanup failed, return immediately.
        if not rawResponse then
            return nil, err
        end

        -- Validate after cleanup so the thumbnail is always removed first.
        return responseValidator.validateAndParse(rawResponse)
    end

    return client
end

-- Create the default production client with real Lightroom SDK dependencies.
local defaultClient = createClient()

--- Create a new OllamaClient with optional dependency overrides.
--- Tests inject fake deps; production callers may omit deps entirely.
---@param deps table|nil Optional dependency overrides
---@return table client New client instance
defaultClient.new = createClient

return defaultClient
