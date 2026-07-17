--- LrLlama.lua — Single-photo metadata generation entry point.
--- Invoked from Library or Export menus. Gets the active catalog and selected photo,
--- builds dependencies for the controller and dialog, and starts the plugin task.

local LrApplication = import "LrApplication"
local LrDialogs     = import "LrDialogs"
local LrTasks       = import "LrTasks"
local LrPrefs       = import "LrPrefs"
local LrPathUtils   = import 'LrPathUtils'

-- Common provides utility functions (parseKeywordCsv, addKeywordsWithParent, etc.)
-- and a delegation layer to OllamaClient for generate/fetchModels operations.
local Common = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "Common.lua"))))()
-- PromptBuilder for the single-photo system prompt override.
local PromptBuilder = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "PromptBuilder.lua"))))()

--- Build a client adapter that exposes the interface SinglePhotoController expects.
--- Common delegates to OllamaClient internally; this adapter maps method names and
--- adapts signatures so the controller has a stable, testable contract.
local function makeClientAdapter(common)
    return {
        --- Delegate to Common.sendDataToApi with matching 7-param signature.
        generate = function(photo, userInstruction, currentData, useCurrentData,
                            useSystemPrompt, selectedModel, systemPromptOverride)
            return common.sendDataToApi(photo, userInstruction, currentData,
                                       useCurrentData, useSystemPrompt,
                                       selectedModel, systemPromptOverride)
        end,

        --- Delegate to Common.fetchAvailableModels (no-arg variant).
        fetchModels = function()
            return common.fetchAvailableModels()
        end,

        -- Direct delegation — signatures match what the controller calls.
        validateServerHost     = common.validateServerHost,
        saveServerAndRefresh   = common.saveServerAndRefresh,
        makeModelItems         = common.makeModelItems,

        -- Constants from OllamaClient via Common.
        defaultModel          = common.model,
        defaultServerHost     = common.defaultServerHost,
    }
end

--- Entry point. Obtains catalog and selected photo, exports a thumbnail,
--- constructs dependencies, and delegates to LlamaDialog for the UI flow.
local function main()
    local catalog = LrApplication.activeCatalog()
    local selectedPhotos = catalog:getTargetPhotos()

    if #selectedPhotos == 0 then
        LrDialogs.message(
            "No photo selected",
            "Please select a photo to view.",
            "critical"
        )
        return
    end

    -- Single-photo mode only processes the first selection.
    local photo = selectedPhotos[1]

    -- Export thumbnail (may fail; dialog will show nothing but won't crash)
    local thumbnailPath = Common.exportThumbnail(photo)

    -- Build the catalog-write adapter. Ensures title, caption, and keyword
    -- mutations happen inside a single catalog transaction.
    local function writeMetadata(catalog, photo, metadata)
        catalog:withWriteAccessDo("Save Llama metadata", function()
            photo:setRawMetadata("title", metadata.title)
            photo:setRawMetadata("caption", metadata.caption)
            if metadata.keywords and #metadata.keywords > 0 then
                Common.addKeywordsWithParent(catalog, photo, metadata.keywords)
            end
        end)
    end

    -- Load the dialog adapter (which in turn creates the controller).
    local LlamaDialog =
        assert(loadfile(LrPathUtils.child(_PLUGIN.path, "LlamaDialog.lua")))()

    LlamaDialog.show({
        client         = makeClientAdapter(Common),
        common         = Common,
        promptBuilder  = PromptBuilder,
        prefs          = LrPrefs.prefsForPlugin(),
        catalog        = catalog,
        photo          = photo,
        thumbnailPath  = thumbnailPath,
        statusMessages = {
            ready      = "Ready",
            generating = "The llama is thinking...",
            refreshing = "Refreshing models...",
        },
        writeMetadata  = writeMetadata,
    })
end

LrTasks.startAsyncTask(main)
