-- Common.lua — Shared utilities for Lightroom Llama plugin
--- Loaded by LrLlama.lua, BatchLrLlama.lua, and ResetMetadata.lua. Provides thumbnail
--- export, Ollama API communication, model discovery, keyword management, and server
--- address validation. All public functions are exported via the return table at EOF.
---
--- SDK imports: LrHttp, LrLogger, LrFileUtils, LrStringUtils, LrTasks, LrPrefs

local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local LrLogger = import 'LrLogger'
local LrFileUtils = import 'LrFileUtils'
local LrStringUtils = import 'LrStringUtils'
local LrTasks = import "LrTasks"
local LrPrefs = import "LrPrefs"

local logger = LrLogger('LrLlama')
logger:enable("logfile") -- Logs to ~/Documents/LrClassicLogs | tail -f LrLlama.log

--- Default Ollama model name; change here to switch models.
---@type string
local model = "gemma4:latest"

--- Fallback server address when prefs are missing, empty, or invalid.
---@type string
local defaultServerHost = "localhost:11434"

--------------------------------------------------------------------------------
-- Validates that a string is in "host:port" form (IP, hostname, or localhost)
-- Returns (true, normalized_host) or (false, error_message)
--------------------------------------------------------------------------------

--- Validate and normalize an Ollama server address.
--- Strips optional scheme (`http://`) and trailing slashes, then verifies the
--- string is `hostname:port`. Accepts localhost, IP addresses, and domain names.
---@param input string|nil User-supplied server address (may be empty)
---@return bool ok    True when the address is valid
---@return string result The normalized host:port on success, error message on failure
local function validateServerHost(input)
    if not input or input == "" then
        return true, defaultServerHost  -- treat empty as "use default"
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

--- Build the base URL for Ollama API calls.
--- Reads `prefs.ollamaServerHost`, validates it, and falls back to
--- `defaultServerHost` if the stored value is malformed. Always returns a valid URL.
---@return string Base URL (e.g., "http://localhost:11434")
local function getOllamaBaseUrl()
    local prefs = LrPrefs.prefsForPlugin()
    local ok, host = validateServerHost(prefs.ollamaServerHost)

    if not ok then
        logger:warn("Invalid server host in prefs: " .. tostring(prefs.ollamaServerHost))
        host = defaultServerHost
    end

    return "http://" .. host
end

JSON = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "JSON.lua"))))()

--------------------------------------------------------------------------------
-- Model discovery
--------------------------------------------------------------------------------

--- Convert a plain list of model names into the `{title, value}` format that
--- LrView `popup_menu` requires for its `items` binding.
---@param modelNames table<string> List of model strings (from fetchAvailableModels)
---@return table<table> Table of `{title = m, value = m}` entries for popup_menu binding
local function makeModelItems(modelNames)
    local items = {}
    for _, m in ipairs(modelNames) do
        table.insert(items, { title = m, value = m })
    end
    return items
end

--- Query Ollama's `/api/tags` endpoint for installed models.
--- Falls back to `{model}` (the default) on network errors, malformed JSON,
--- or an empty model list — so callers never receive nil.
---@return table<string> List of model name strings; always non-empty.
local function fetchAvailableModels()
    logger:info("Fetching available models from Ollama")

    local url = getOllamaBaseUrl() .. "/api/tags"
    local response = LrHttp.get(url)

    if response then
        local decodeSuccess, data = pcall(function()
            return JSON:decode(response)
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
                logger:info("Found " .. #modelList .. " models")
                return modelList
            end

            logger:warn("Ollama returned an empty model list")
        elseif not decodeSuccess then
            logger:warn(
                "Failed to decode Ollama model response: " .. tostring(data)
            )
        else
            logger:warn("Ollama response did not contain a valid model list")
        end
    else
        logger:warn("No response received from Ollama")
    end

    logger:warn("Using default model: " .. model)
    return { model }
end

--- Persist the server host and rebuild the model dropdown.
--- MUST be called from within `LrTasks.startAsyncTask()` — LrBinding only
--- propagates property reassignments (modelItems, selectedModel) when done
--- off the UI thread.
---@param props table LrBinding property table containing serverHost, modelItems, selectedModel
---@param prefs table LrPrefs prefsForPlugin() instance
---@return bool ok True on success
---@return string message Human-readable status or error description
local function saveServerAndRefresh(props, prefs)
    local ok, validatedHost = validateServerHost(props.serverHost)
    if not ok then
        return false, validatedHost  -- caller displays error
    end

    prefs.ollamaServerHost = validatedHost

    local availableModels = fetchAvailableModels()
    if not availableModels or #availableModels == 0 then
        return false, "No models found on server"
    end

    -- Rebuild model list. This function is intended to be called from inside
    -- LrTasks.startAsyncTask() so that LrBinding picks up the property
    -- reassignment and propagates it to the dialog's popup_menu.
    local oldSelection = props.selectedModel or ""
    props.modelItems = makeModelItems(availableModels)

    -- Keep old selection if it still exists in the new list
    local found = false
    for _, m in ipairs(availableModels) do
        if m == oldSelection then found = true; break; end
    end
    props.selectedModel = found and oldSelection or availableModels[1]

    return true, string.format("Loaded %d model(s)", #availableModels)
end

--- Export a 512×512 JPEG thumbnail to a unique temp file.
--- **Side effect:** writes a file to the system temp directory.
--- Caller is responsible for deleting the returned file after use.
---@param photo LrPhoto Photo object from the catalog
---@return string|nil Absolute path on success, nil on failure
local function exportThumbnail(photo)
    local tempPath = LrFileUtils.chooseUniqueFileName(LrPathUtils.getStandardFilePath('temp') .. "/thumbnail.jpg")
    logger:info("Attempting to export thumbnail to: " .. tempPath)

    -- Validate that the temp directory exists and is accessible before proceeding
    -- This prevents silent failures when the temp directory is missing or restricted
    local tempDir = LrPathUtils.getStandardFilePath('temp')
    if not LrFileUtils.exists(tempDir) then
        logger:error("Temp directory does not exist: " .. tempDir)
        return nil
    end

    -- Track whether the thumbnail callback successfully wrote data
    -- This flag is set inside the callback to communicate success back to the caller
    local thumbnailSaved = false
    -- Request a 512x512 JPEG thumbnail asynchronously
    -- photo:requestJpegThumbnail() returns (success, result) and executes the callback
    -- with the JPEG binary data if available
    local success, result = photo:requestJpegThumbnail(512, 512, function(jpegData)
        if jpegData then
            -- Open temp file in binary write mode ("wb") to preserve JPEG data integrity
            local tempFile = io.open(tempPath, "wb")
            if tempFile then
                tempFile:write(jpegData)
                tempFile:close()
                thumbnailSaved = true
                logger:info("Thumbnail saved to " .. tempPath)
                return true
            else
                logger:error("Could not open temp file for writing: " .. tempPath)
                return false
            end
        else
            logger:error("No JPEG data received from photo")
            return false
        end
    end)

    -- Verify both the API call succeeded AND the callback wrote the file
    if success and thumbnailSaved then
        -- Final verification: ensure the file actually exists on disk
        -- This catches edge cases where the write appeared successful but the file is missing
        if LrFileUtils.exists(tempPath) then
            logger:info("Thumbnail export successful: " .. tempPath)
            return tempPath
        else
            logger:error("Thumbnail file was not created: " .. tempPath)
            return nil
        end
    else
        logger:warn("Failed to export thumbnail. Success: " .. tostring(success) .. ", Result: " .. tostring(result))
        return nil
    end
end

--------------------------------------------------------------------------------
-- Base64 encoding
--------------------------------------------------------------------------------

--- Read a JPEG file and return its Base64-encoded representation.
---@param imagePath string Absolute path to the JPEG file
---@return string|nil Base64 string on success, nil if file unreadable or empty
local function base64EncodeImage(imagePath)
    logger:info("Attempting to encode image: " .. imagePath)

    -- Check if file exists
    if not LrFileUtils.exists(imagePath) then
        logger:error("Image file does not exist: " .. imagePath)
        return nil
    end

    local file = io.open(imagePath, "rb")
    if not file then
        logger:error("Could not open file for reading: " .. imagePath)
        return nil
    end

    local binaryData = file:read("*all")
    file:close()

    if not binaryData or #binaryData == 0 then
        logger:error("No data read from file: " .. imagePath)
        return nil
    end

    local base64Data = LrStringUtils.encodeBase64(binaryData)
    if not base64Data then
        logger:error("Failed to encode image to base64: " .. imagePath)
        return nil
    end

    logger:info("Successfully encoded image to base64. Size: " .. #binaryData .. " bytes")
    return base64Data
end

--------------------------------------------------------------------------------
-- Default system prompt (the more detailed version from BatchLrLlama.lua)
--------------------------------------------------------------------------------

local defaultSystemPrompt = [[# Image Metadata Generation Prompt

You are an expert content curator specializing in creating compelling, accurate metadata for visual content. Your task is to analyze the provided image/video and generate a JSON object with three components: title, caption, and keywords.

## Output Format
Return your response as a valid JSON object with this exact structure:
```json
{
  "title": "string",
  "caption": "string",
  "keywords": ["string", "string", "string"]
}
```

## Guidelines

### Title Requirements
- **Length**: 5-12 words maximum
- **Style**: Write as a descriptive headline, not a sentence
- **Content**: Capture the main subject, action, and context
- **Focus**: Answer "what is happening" in the most compelling way
- **Avoid**: Generic terms, keyword stuffing, colons, redundant phrases
- **Include**: Specific details like location, time of day, or unique elements when relevant

**Good examples:**
- "Mountain climber reaching summit during golden hour"
- "Children playing soccer in urban park"
- "Vintage red bicycle against brick wall"

### Caption Requirements
- **Length**: 15-40 words
- **Style**: Complete sentences that expand on the title
- **Content**: Provide context, mood, or story behind the image
- **Focus**: Add emotional resonance or background information
- **Avoid**: Repeating the exact title wording
- **Include**: Atmosphere, setting details, or cultural context when relevant

**Good example:**
*Title: "Street musician performing violin solo in subway station"*
*Caption: "A talented violinist captivates commuters with classical music during evening rush hour, creating a moment of beauty in the bustling underground transit hub."*

### Keywords Requirements
- **Quantity**: 10-30 keywords (aim for 15-20 for optimal results)
- **Hierarchy**: Order from most specific to more general
- **Categories**: Include subjects, actions, emotions, locations, styles, colors, concepts
- **Format**: Single words or short phrases (2-3 words max)
- **Avoid**: Repeating title/caption words exactly, overly generic terms, technical camera specs

**Keyword categories to consider:**
- Primary subjects (people, objects, animals)
- Actions and verbs
- Emotions and moods
- Locations and settings
- Colors and lighting
- Art styles or techniques
- Concepts and themes
- Seasonal or temporal elements

## Quality Checklist
Before finalizing, ensure:
- [ ] Title is unique and descriptive without being generic
- [ ] Caption adds meaningful context beyond the title
- [ ] Keywords cover multiple relevant categories
- [ ] No unnecessary repetition across all three elements
- [ ] JSON format is valid and properly structured
- [ ] Content accurately reflects what's actually in the image

## Example Output
```json
{
  "title": "Barista creating latte art in cozy downtown cafe",
  "caption": "Skilled coffee artist carefully pours steamed milk to create an intricate leaf pattern, showcasing the craftsmanship behind specialty coffee culture in a warm, inviting neighborhood coffee shop.",
  "keywords": ["barista", "latte art", "coffee shop", "cafe culture", "milk foam", "artisan", "beverage preparation", "downtown", "craftsmanship", "morning routine", "specialty coffee", "hospitality", "small business", "urban lifestyle", "food service"]
}
```
]]

--------------------------------------------------------------------------------
-- API communication
--- Export a thumbnail, encode it as Base64, and POST to Ollama's `/api/generate`.
--- Retries thumbnail export up to 3 times. Cleans up the temp file after the
--- HTTP request regardless of success or failure. Validates the JSON response
--- has title (string), caption (string), and keywords (array of non-empty strings).
---@param photo LrPhoto Photo object from the catalog
---@param prompt string User-facing prompt text
---@param currentData table|nil Existing title/caption to prepend when useCurrentData is true
---@param useCurrentData boolean Whether to include current metadata in the prompt
---@param useSystemPrompt boolean Whether to send a system prompt alongside the user prompt
---@param selectedModel string|nil Model name; falls back to the default if nil
---@param systemPrompt string|nil Override for the built-in system prompt
---@return table|nil response Parsed JSON on success ({title, caption, keywords})
---@return string|nil err Error message, or nil on success
local function sendDataToApi(photo, prompt, currentData, useCurrentData, useSystemPrompt, selectedModel, systemPrompt)
    logger:info("Sending data to API")

    -- Try to export thumbnail with retry
    local thumbnailPath = nil
    for attempt = 1, 3 do
        thumbnailPath = exportThumbnail(photo)
        if thumbnailPath then
            break
        end
        logger:warn("Thumbnail export attempt " .. attempt .. " failed, retrying...")
        LrTasks.sleep(0.5) -- Wait 500ms before retry
    end

    if not thumbnailPath then
        return nil, "Failed to export thumbnail after 3 attempts"
    end

    local encodedImage = base64EncodeImage(thumbnailPath)
    if not encodedImage then
        return nil, "Failed to encode image"
    end

    local url = getOllamaBaseUrl() .. "/api/generate"

    -- Choose system prompt: caller-provided > default
    local activeSystemPrompt = systemPrompt or defaultSystemPrompt

    local postData = {
        model = selectedModel or model,
        prompt = (useCurrentData and "Title: "..(currentData.title or ""):gsub('"', '\\"') .. " Caption: "..(currentData.caption or ""):gsub('"', '\\"') .. " " .. prompt) or prompt,
        format = "json",
        system = useSystemPrompt and activeSystemPrompt or nil,
        images = {encodedImage},
        stream = false
    }

    local jsonPayload = JSON:encode(postData)

    local response, headers = LrHttp.post(url, jsonPayload, {{
        field = "Content-Type",
        value = "application/json"
    }})

    -- Clean up thumbnail file
    LrFileUtils.delete(thumbnailPath)

    if response then
        -- Decode outer Ollama API response
        local decodeOk1, response_data = pcall(function()
            return JSON:decode(response)
        end)

        if not decodeOk1
            or type(response_data) ~= "table"
            or type(response_data.response) ~= "string" then
            logger:warn("Invalid API response structure: " .. tostring(response_data))
            return nil, "Invalid API response structure"
        end

        local rawResponse = response_data.response

        -- Many Ollama models emit markdown-wrapped JSON ("```json\n{...}\n```").
        -- Strip the fences so JSON:decode receives bare JSON. Two patterns handle
        -- both ```json and bare ``` variants.
        rawResponse = string.gsub(rawResponse, "^%s*```%w+\n?", "")
        rawResponse = string.gsub(rawResponse, "\n?```%s*$", "")
        rawResponse = string.gsub(rawResponse, "^%s*```%s*\n?", "")
        rawResponse = string.gsub(rawResponse, "\n?```%s*$", "")

        -- Decode the model-generated JSON
        local decodeOk2, response_json = pcall(function()
            return JSON:decode(rawResponse)
        end)

        if not decodeOk2 or type(response_json) ~= "table" then
            logger:warn("Invalid JSON in API response: " .. tostring(response_json))
            return nil, "Invalid JSON in API response"
        end

        -- Validate required fields exist with correct types
        if type(response_json.title) ~= "string" or
           type(response_json.caption) ~= "string" or
           type(response_json.keywords) ~= "table" then
            logger:warn("API response missing required fields (title, caption, keywords)")
            return nil, "API response missing required fields (title, caption, keywords)"
        end

        -- Validate each keyword entry is a non-empty string
        for _, kw in ipairs(response_json.keywords) do
            if type(kw) ~= "string" or kw:match("^%s*$") then
                logger:warn("API response contains an invalid keyword entry")
                return nil, "API response contains an invalid keyword"
            end
        end

        return response_json, nil
    else
        return nil, "Failed to send data to the API"
    end
end

--------------------------------------------------------------------------------
-- Keyword management
--------------------------------------------------------------------------------

--- Add keywords under the `llm` parent keyword.
--- Creates (or retrieves) a top-level `llm` keyword, then adds each entry as a child
--- and associates it with the photo. Idempotent — safe to call on photos that
--- already have LLM keywords.
---@param catalog LrCatalog Active catalog (from LrApplication.activeCatalog())
---@param photo LrPhoto Target photo
---@param keywords table<string> Array of keyword strings
local function addKeywordsWithParent(catalog, photo, keywords)
    if not keywords or type(keywords) ~= "table" then
        return
    end

    -- First create or get the parent 'llm' keyword
    local llmKeyword = catalog:createKeyword("llm", nil, true, nil, true)
    if not llmKeyword then
        error("Failed to create or get 'llm' parent keyword")
    end

    for _, keyword in ipairs(keywords) do
        if keyword and keyword ~= "" then
            -- Create child keyword under 'llm' parent
            local childKeyword = catalog:createKeyword(keyword, nil, true, llmKeyword, true)
            if childKeyword then
                photo:addKeyword(childKeyword)
            else
                logger:warn("Failed to create keyword: " .. tostring(keyword))
            end
        end
    end
end

--- Read existing LLM-generated keywords from a photo.
--- Filters all keywords to only those whose parent is `llm`. Wrapped in
--- `pcall` so that malformed keyword data doesn't crash the plugin.
---@param photo LrPhoto Target photo
---@return table<string> Array of keyword name strings (may be empty)
local function getLlmKeywordsFromPhoto(photo)
    local llmKeywords = {}

    -- Wrap in pcall to catch any errors
    local success, result = pcall(function()
        local allKeywords = photo:getRawMetadata("keywords")

        if allKeywords then
            for _, keyword in ipairs(allKeywords) do
                local parent = keyword:getParent()
                if parent and parent:getName() == "llm" then
                    table.insert(llmKeywords, keyword:getName())
                end
            end
        end
    end)

    if not success then
        logger:warn("Error getting LLM keywords: " .. tostring(result))
        return {} -- Return empty array on error
    end

    return llmKeywords
end

--- Remove all `llm`-parented keywords from a photo.
--- Only removes the keyword-to-photo association — does not delete the keyword
--- definitions from the catalog (other photos may reference them).
---@param catalog LrCatalog Active catalog
---@param photo LrPhoto Target photo
local function removeLlmKeywords(catalog, photo)
    local allKeywords = photo:getRawMetadata("keywords")
    if not allKeywords then
        return
    end

    local keywordsToRemove = {}
    for _, keyword in ipairs(allKeywords) do
        local parent = keyword:getParent()
        if parent and parent:getName() == "llm" then
            table.insert(keywordsToRemove, keyword)
        end
    end

    for _, keyword in ipairs(keywordsToRemove) do
        photo:removeKeyword(keyword)
    end
end

--------------------------------------------------------------------------------
--- Public API — imported by LrLlama.lua, BatchLrLlama.lua, ResetMetadata.lua
--------------------------------------------------------------------------------

return {
    model = model,
    defaultServerHost = defaultServerHost,
    validateServerHost = validateServerHost,
    makeModelItems = makeModelItems,
    fetchAvailableModels = fetchAvailableModels,
    saveServerAndRefresh = saveServerAndRefresh,
    exportThumbnail = exportThumbnail,
    base64EncodeImage = base64EncodeImage,
    sendDataToApi = sendDataToApi,
    addKeywordsWithParent = addKeywordsWithParent,
    getLlmKeywordsFromPhoto = getLlmKeywordsFromPhoto,
    removeLlmKeywords = removeLlmKeywords,
}
