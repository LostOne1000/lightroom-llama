-- Common.lua — Shared utilities for Lightroom Llama plugin (delegation layer).
--- Loads the focused modules and re-exports them under the original names used by
--- LrLlama.lua, BatchLrLlama.lua, and ResetMetadata.lua. This allows a zero-downtime
--- migration: entry points continue calling Common.X() while logic lives in dedicated
--- modules (OllamaClient, ThumbnailService, PromptBuilder, ResponseValidator,
--- MetadataService). Once verified, the delegation wrappers can be removed and
--- entry points updated to load modules directly.

local LrPrefs = import "LrPrefs"
local LrPathUtils = import 'LrPathUtils'

-- Load focused modules
local OllamaClient = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "OllamaClient.lua"))))()
local ThumbnailService = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "ThumbnailService.lua"))))()
local MetadataService = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "MetadataService.lua"))))()

return {
    -- OllamaClient constants
    model = OllamaClient.defaultModel,
    defaultServerHost = OllamaClient.defaultServerHost,

    -- OllamaClient functions (direct delegation)
    validateServerHost = OllamaClient.validateServerHost,
    makeModelItems = OllamaClient.makeModelItems,
    saveServerAndRefresh = OllamaClient.saveServerAndRefresh,

    -- fetchAvailableModels wraps client.fetchModels to provide no-arg compatibility
    fetchAvailableModels = function()
        return OllamaClient.fetchModels(LrPrefs.prefsForPlugin())
    end,

    -- ThumbnailService functions (direct delegation)
    exportThumbnail = ThumbnailService.export,
    base64EncodeImage = ThumbnailService.encodeBase64,

    -- OllamaClient.generate is the decomposition of sendDataToApi; same 7-param signature.
    sendDataToApi = function(photo, prompt, currentData, useCurrentData,
                            useSystemPrompt, selectedModel, systemPrompt)
        return OllamaClient.generate(photo, prompt, currentData, useCurrentData,
                                     useSystemPrompt, selectedModel, systemPrompt)
    end,

    -- MetadataService functions (direct delegation)
    addKeywordsWithParent = MetadataService.addKeywordsWithParent,
    getLlmKeywordsFromPhoto = MetadataService.getLlmKeywordsFromPhoto,
    removeLlmKeywords = MetadataService.removeLlmKeywords,
    parseKeywordCsv = MetadataService.parseKeywordCsv,
}
