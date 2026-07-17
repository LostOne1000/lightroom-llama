--- Common.lua — Shared utilities for Lightroom Llama plugin (delegation layer).
--- Loads the focused modules and re-exports them under the original names used by
--- LrLlama.lua, BatchLrLlama.lua, and ResetMetadata.lua. This allows a zero-downtime
--- migration: entry points continue calling Common.X() while logic lives in dedicated
--- modules (OllamaClient, ThumbnailService, PromptBuilder, ResponseValidator,
--- MetadataService). Once verified, the delegation wrappers can be removed and
--- entry points updated to load modules directly.
---
--- For testing, the exported `new` constructor accepts fake focused modules so that
--- delegation behavior can be verified without the Lightroom SDK.

local LrPrefs = import "LrPrefs"
local LrPathUtils = import 'LrPathUtils'

--------------------------------------------------------------------------------
--- Factory — build a Common compatibility object from dependency modules.
--- Production code uses the default instance returned at module load time;
--- tests call `common.new(deps)` with fake modules to verify delegation.
---
--- All delegations use explicit wrapper functions (not direct reference
--- assignments) so that test harnesses can swap out fake implementations
--- between construction and invocation and observe correct forwarding.
---@param deps table Dependency map:
---   { ollamaClient, thumbnailService, metadataService, prefsService }
---   - ollamaClient: OllamaClient module (defaultModel, defaultServerHost,
---     validateServerHost, makeModelItems, saveServerAndRefresh, fetchModels, generate)
---   - thumbnailService: ThumbnailService module (export, encodeBase64)
---   - metadataService: MetadataService module
---     (addKeywordsWithParent, getLlmKeywordsFromPhoto, removeLlmKeywords, parseKeywordCsv)
---   - prefsService: LrPrefs module with prefsForPlugin()
---@return table Common compatibility object with all expected exports
local function createCommon(deps)
    local ollamaClient = assert(deps.ollamaClient, "deps.ollamaClient is required")
    local thumbnailService = assert(deps.thumbnailService, "deps.thumbnailService is required")
    local metadataService = assert(deps.metadataService, "deps.metadataService is required")
    local prefsService = assert(deps.prefsService, "deps.prefsService is required")

    return {
        -- OllamaClient constants
        model = ollamaClient.defaultModel,
        defaultServerHost = ollamaClient.defaultServerHost,

        -- OllamaClient functions — explicit wrappers for testability.
        -- Direct reference assignment would capture the function at construction
        -- time, preventing tests from verifying delegation behavior.
        validateServerHost = function(...)
            return ollamaClient.validateServerHost(...)
        end,
        makeModelItems = function(...)
            return ollamaClient.makeModelItems(...)
        end,
        saveServerAndRefresh = function(...)
            return ollamaClient.saveServerAndRefresh(...)
        end,

        -- fetchAvailableModels wraps client.fetchModels to provide no-arg compatibility
        fetchAvailableModels = function()
            return ollamaClient.fetchModels(prefsService.prefsForPlugin())
        end,

        -- ThumbnailService functions — explicit wrappers for testability.
        exportThumbnail = function(...)
            return thumbnailService.export(...)
        end,
        base64EncodeImage = function(...)
            return thumbnailService.encodeBase64(...)
        end,

        -- OllamaClient.generate is the decomposition of sendDataToApi; same 7-param signature.
        sendDataToApi = function(photo, prompt, currentData, useCurrentData,
                                useSystemPrompt, selectedModel, systemPrompt)
            return ollamaClient.generate(photo, prompt, currentData, useCurrentData,
                                         useSystemPrompt, selectedModel, systemPrompt)
        end,

        -- MetadataService functions — explicit wrappers for testability.
        addKeywordsWithParent = function(...)
            return metadataService.addKeywordsWithParent(...)
        end,
        getLlmKeywordsFromPhoto = function(...)
            return metadataService.getLlmKeywordsFromPhoto(...)
        end,
        removeLlmKeywords = function(...)
            return metadataService.removeLlmKeywords(...)
        end,
        parseKeywordCsv = function(...)
            return metadataService.parseKeywordCsv(...)
        end,
    }
end

-- Load focused modules for the default production instance.
local OllamaClient = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "OllamaClient.lua"))))()
local ThumbnailService = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "ThumbnailService.lua"))))()
local MetadataService = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "MetadataService.lua"))))()

-- Create the default production compatibility object.
local common = createCommon({
    ollamaClient = OllamaClient,
    thumbnailService = ThumbnailService,
    metadataService = MetadataService,
    prefsService = LrPrefs,
})

--- Create a new Common compatibility object with custom dependencies.
--- Used by tests to inject fake focused modules. Production callers ignore this.
---@param deps table Dependency map with ollamaClient, thumbnailService, metadataService, prefsService
---@return table New Common compatibility object
common.new = createCommon

return common
