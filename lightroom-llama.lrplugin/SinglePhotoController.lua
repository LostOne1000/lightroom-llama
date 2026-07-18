--- SinglePhotoController.lua — Testable workflow logic for single-photo metadata
--- generation. Owns state transitions for generate, save-server, and save-metadata
--- actions without any Lightroom SDK dependencies (no LrView, LrBinding, LrColor,
--- LrDialogs, or LrFunctionContext).
---
--- Inject dependencies via the constructor; each operation returns structured
--- results ({ok, message}) and mutates the state table in place so that callers
--- using the same table as an LrBinding property table see live updates.

local controller = {}

--------------------------------------------------------------------------------
--- Constructor — validate dependencies and return a controller instance.
---@param deps table Dependency map:
---   { client, common, promptBuilder, prefs, catalog, photo, statusMessages, writeMetadata }
---   - client:      OllamaClient instance (generate, fetchModels, validateServerHost,
---                  saveServerAndRefresh, makeModelItems, defaultModel, defaultServerHost)
---   - common:      Utility functions { parseKeywordCsv, getLlmKeywordsFromPhoto }
---   - promptBuilder: PromptBuilder module with singlePhotoSystemPrompt
---   - prefs:       LrPrefs.prefsForPlugin() table for persistence
---   - catalog:     LrCatalog active catalog
---   - photo:       LrPhoto selected photo
---   - statusMessages: { ready, generating, refreshing } status strings
---   - writeMetadata: function(catalog, photo) callback for catalog writes
---                     (wraps withWriteAccessDo in production; faked in tests)
---@return table controller Instance with initState, generate, saveServer, saveMetadata
function controller.new(deps)
    assert(deps.client,      "deps.client is required")
    assert(deps.common,      "deps.common is required")
    assert(deps.prefs,       "deps.prefs is required")
    assert(deps.catalog,     "deps.catalog is required")
    assert(deps.photo,       "deps.photo is required")

    local promptBuilder  = deps.promptBuilder
    local statusMessages = deps.statusMessages or {}

    return {
        initState      = function() return controller.initState(deps, promptBuilder, statusMessages) end,
        generate       = function(state) return controller.generate(deps, state) end,
        saveServer     = function(state) return controller.saveServer(deps, state) end,
        saveMetadata   = function(state) return controller.saveMetadata(deps, state) end,
    }
end

--------------------------------------------------------------------------------
-- Initial state creation
--------------------------------------------------------------------------------

--- Build the initial state table by reading photo metadata, loading preferences,
--- and fetching available models.
local function initState(deps, promptBuilder, statusMessages)
    local client = deps.client
    local common = deps.common
    local prefs  = deps.prefs
    local photo  = deps.photo

    local state = {}

    -- Read existing photo metadata
    state.title    = photo:getFormattedMetadata("title")    or ""
    state.caption  = photo:getFormattedMetadata("caption")  or ""

    -- Read existing LLM keywords and join with commas
    local existingKw = common.getLlmKeywordsFromPhoto(photo)
    state.keywords = table.concat(existingKw, ", ")

    -- Enable "use current data" when there's metadata to work from
    state.useCurrentData = (state.title ~= "" or state.caption ~= "")

    -- Server host: saved preference or default
    state.serverHost = prefs.ollamaServerHost or client.defaultServerHost
    state.useSystemPrompt = true

    -- Fetch models and populate dropdown items. The adapter may or may not accept
    -- a prefs argument; call it with no args (prefs are internal to the adapter).
    local models = client.fetchModels()
    if not models or #models == 0 then
        models = { client.defaultModel }
    end
    state.modelItems     = client.makeModelItems(models)
    state.selectedModel  = models[1]

    -- Prompt and status defaults
    state.prompt     = "Caption this photo"
    state.response   = nil
    state.status     = statusMessages.ready    or "Ready"
    state.statusKind = "success"

    return state
end

controller.initState = initState

--------------------------------------------------------------------------------
-- Generate action
--------------------------------------------------------------------------------

--- Call the API to generate metadata for the current photo.
--- Sets status to working before the call, success/error after.
--- On failure, preserves existing editable fields (title, caption, keywords).
---@param state table Mutable state table (also used as LrBinding property table)
---@return table result { ok: bool, message?: string }
local function generate(deps, state)
    local client = deps.client
    local statusMessages = deps.statusMessages or {}

    -- Transition to working status
    state.status     = statusMessages.generating or "The llama is thinking..."
    state.statusKind = "working"

    -- Snapshot current editable fields so we can restore on failure
    local savedTitle    = state.title
    local savedCaption  = state.caption
    local savedKeywords = state.keywords

    local apiResponse, apiError = deps.client.generate(
        deps.photo,
        state.prompt,
        { title = state.title, caption = state.caption },
        state.useCurrentData,
        state.useSystemPrompt,
        state.selectedModel,
        deps.promptBuilder and deps.promptBuilder.singlePhotoSystemPrompt or nil
    )

    if apiError then
        -- Restore editable fields on failure
        state.title    = savedTitle
        state.caption  = savedCaption
        state.keywords = savedKeywords
        state.status     = "Error: " .. apiError
        state.statusKind = "error"
        return { ok = false, message = "Error: " .. apiError }
    end

    -- Update from API response on success
    state.response = apiResponse
    state.title    = apiResponse.title
    state.caption  = apiResponse.caption
    if apiResponse.keywords and type(apiResponse.keywords) == "table" then
        state.keywords = table.concat(apiResponse.keywords, ", ")
    else
        state.keywords = ""
    end
    state.status     = statusMessages.ready or "Ready"
    state.statusKind = "success"
    return { ok = true }
end

controller.generate = generate

--------------------------------------------------------------------------------
-- Save Server action
--------------------------------------------------------------------------------

--- Validate and persist the server host, then refresh the model list.
--- Callers are responsible for running this from an async task (LrBinding
--- propagation requires off-UI-thread property mutations).
---@param state table Mutable state table
---@return table result { ok: bool, message?: string }
local function saveServer(deps, state)
    local statusMessages = deps.statusMessages or {}

    state.status     = statusMessages.refreshing or "Refreshing models..."
    state.statusKind = "working"

    local ok, msg = deps.client.saveServerAndRefresh(state, deps.prefs)

    if not ok then
        state.status     = "Error: " .. (msg or "Failed to save server")
        state.statusKind = "error"
        return { ok = false, message = state.status }
    end

    state.status     = msg
    state.statusKind = "success"
    return { ok = true, message = msg }
end

controller.saveServer = saveServer

--------------------------------------------------------------------------------
-- Save Metadata action
--------------------------------------------------------------------------------

--- Validate server host, persist preferences, and write metadata through the
--- injected write function. Returns a structured result so callers (and tests)
--- can distinguish validation failure from successful saves.
---@param state table Mutable state table
---@return table result { ok: bool, message?: string, errorKind?: string }
local function saveMetadata(deps, state)
    -- Validate and normalize server host
    local ok, validatedHost = deps.client.validateServerHost(state.serverHost)
    if not ok then
        return {
            ok = false,
            errorKind = "invalid_server",
            message = validatedHost,
        }
    end

    -- Save normalized host to preferences (only when valid)
    deps.prefs.ollamaServerHost = validatedHost

    -- Parse keywords using the tested CSV parser
    local keywordList = {}
    if state.keywords and state.keywords ~= "" then
        keywordList = deps.common.parseKeywordCsv(state.keywords)
    end

    -- Execute catalog writes through injected adapter
    deps.writeMetadata(deps.catalog, deps.photo, {
        title    = state.title,
        caption  = state.caption,
        keywords = keywordList,
    })

    return { ok = true }
end

controller.saveMetadata = saveMetadata

return controller
