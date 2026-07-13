local LrApplication = import "LrApplication"
local LrDialogs = import "LrDialogs"
local LrView = import "LrView"
local LrTasks = import "LrTasks"
local LrFunctionContext = import "LrFunctionContext"
local LrBinding = import "LrBinding"
local LrColor = import "LrColor"
local LrProgressScope = import "LrProgressScope"
local LrPrefs = import "LrPrefs"
local LrPathUtils = import 'LrPathUtils'

-- Load shared utilities (includes logger, model constant, JSON loader, shared functions)
local Common = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "Common.lua"))))()

--------------------------------------------------------------------------------
-- Batch processing results display
--------------------------------------------------------------------------------

local function showBatchResults(results)
    local successful = 0
    local failed = 0
    local skipped = 0

    for _, result in ipairs(results) do
        if result.success then
            if result.error and string.find(result.error, "Skipped") then
                skipped = skipped + 1
            else
                successful = successful + 1
            end
        else
            failed = failed + 1
        end
    end

    -- Only show popup if there are failures
    if failed > 0 then
        local message = string.format(
            "Batch processing complete!\n\nSuccessful: %d\nSkipped: %d\nFailed: %d\n\nTotal processed: %d photos",
            successful, skipped, failed, #results
        )

        local failedPhotos = {}
        for _, result in ipairs(results) do
            if not result.success then
                local photoName = result.photo:getFormattedMetadata('fileName') or "Unknown"
                table.insert(failedPhotos, photoName .. ": " .. (result.error or "Unknown error"))
            end
        end

        message = message .. "\n\nFailed photos:\n" .. table.concat(failedPhotos, "\n")

        LrDialogs.message("Batch Processing Results", message, "info")
    end
    -- If all successful, no popup is shown
end

--------------------------------------------------------------------------------
-- Batch dialog + processing
--------------------------------------------------------------------------------

local function showBatchDialog(selectedPhotos)
    LrFunctionContext.callWithContext("showBatchDialog", function(context)
        local props = LrBinding.makePropertyTable(context)
        local prefs = LrPrefs.prefsForPlugin()

        -- Initialize with default values or saved preferences
        props.prompt = prefs.batchPrompt or "Caption this photo"
        props.useCurrentData = prefs.batchUseCurrentData or false
        props.useSystemPrompt = prefs.batchUseSystemPrompt ~= false -- Default to true
        props.skipExisting = prefs.batchSkipExisting ~= false -- Default to true
        props.generateTitle = prefs.batchGenerateTitle ~= false -- Default to true
        props.generateCaption = prefs.batchGenerateCaption ~= false -- Default to true
        props.generateKeywords = prefs.batchGenerateKeywords ~= false -- Default to true

        -- Fetch available models from Ollama and populate the dropdown
        local availableModels = Common.fetchAvailableModels()
        props.modelItems = {}
        for _, m in ipairs(availableModels) do
            table.insert(props.modelItems, { title = m, value = m })
        end
        props.selectedModel = prefs.batchSelectedModel or availableModels[1]  -- restore preference or default to first

        local f = LrView.osFactory()

        local c = f:view{
            bind_to_object = props,
            f:column{
                f:static_text{
                    title = string.format("Batch process %d selected photos with Llama", #selectedPhotos),
                    font = "<system/bold>"
                },
                f:spacer{height = 20},

                f:static_text{title = "Prompt:"},
                f:spacer{f:label_spacing{}},
                f:edit_field{
                    value = LrView.bind("prompt"),
                    width = 400,
                    height = 60
                },
                f:spacer{height = 15},

                f:checkbox{
                    title = "Use current title and caption data",
                    value = LrView.bind("useCurrentData")
                },
                f:spacer{height = 10},

                f:checkbox{
                    title = "Use system prompt (recommended)",
                    value = LrView.bind("useSystemPrompt")
                },
                f:spacer{height = 10},

                f:checkbox{
                    title = "Skip photos that already have LLM keywords",
                    value = LrView.bind("skipExisting")
                },
                f:spacer{height = 20},

                f:static_text{title = "Generate:", font = "<system/bold>"},
                f:spacer{height = 10},

                f:checkbox{title = "Title", value = LrView.bind("generateTitle")},
                f:spacer{height = 5},

                f:checkbox{title = "Caption", value = LrView.bind("generateCaption")},
                f:spacer{height = 5},

                f:checkbox{title = "Keywords", value = LrView.bind("generateKeywords")},
                f:spacer{height = 20},

                f:separator{width = 400},
                f:spacer{height = 10},

                f:static_text{title = "Model:", alignment = 'left'},
                f:spacer{f:label_spacing{}},
                f:popup_menu{
                    value = LrView.bind("selectedModel"),
                    items = props.modelItems,
                    width = 250,
                },
                f:spacer{height = 10},

                f:static_text{
                    title = "Note: This process may take several minutes depending on the number of photos.",
                    font = "<system>",
                    text_color = LrColor(0.6, 0.6, 0.6)
                }
            }
        }

        local result = LrDialogs.presentModalDialog({
            title = "Batch Process with Llama",
            contents = c,
            actionVerb = "Start Processing"
        })

        if result == "ok" then
            -- Save preferences for next time
            prefs.batchPrompt = props.prompt
            prefs.batchUseCurrentData = props.useCurrentData
            prefs.batchUseSystemPrompt = props.useSystemPrompt
            prefs.batchSkipExisting = props.skipExisting
            prefs.batchGenerateTitle = props.generateTitle
            prefs.batchGenerateCaption = props.generateCaption
            prefs.batchGenerateKeywords = props.generateKeywords
            prefs.batchSelectedModel = props.selectedModel

            local settings = {
                prompt = props.prompt,
                useCurrentData = props.useCurrentData,
                useSystemPrompt = props.useSystemPrompt,
                skipExisting = props.skipExisting,
                generateTitle = props.generateTitle,
                generateCaption = props.generateCaption,
                generateKeywords = props.generateKeywords,
                selectedModel = props.selectedModel
            }

            -- Process with progress scope
            local results = {}
            local catalog = LrApplication.activeCatalog()

            LrFunctionContext.callWithContext("batchProcessing", function(context)
                local progressScope = LrProgressScope({
                    title = "Processing photos with Llama",
                    functionContext = context
                })

                progressScope:setPortionComplete(0, #selectedPhotos)

                for i, photo in ipairs(selectedPhotos) do
                    if progressScope:isCanceled() then
                        break
                    end

                    local photoName = photo:getFormattedMetadata('fileName') or "Photo " .. i
                    progressScope:setCaption("Processing: " .. photoName)

                    local result = {
                        photo = photo,
                        success = false,
                        error = nil,
                        metadata = nil
                    }

                    -- Check if we should skip photos with existing LLM keywords
                    local shouldSkip = false
                    if settings.skipExisting then
                        local existingKeywords = Common.getLlmKeywordsFromPhoto(photo)
                        if #existingKeywords > 0 then
                            result.success = true
                            result.error = "Skipped - already has LLM keywords"
                            shouldSkip = true
                        end
                    end

                    if not shouldSkip then
                        -- Get current metadata
                        local currentData = {
                            title = photo:getFormattedMetadata('title') or "",
                            caption = photo:getFormattedMetadata('caption') or ""
                        }

                        -- Process photo with API
                        local apiResponse, apiError = Common.sendDataToApi(
                            photo, settings.prompt, currentData,
                            settings.useCurrentData, settings.useSystemPrompt,
                            settings.selectedModel
                        )

                        if apiResponse then
                            result.success = true
                            result.metadata = apiResponse
                        else
                            result.error = apiError or "Unknown API error"
                        end
                    end

                    table.insert(results, result)
                    progressScope:setPortionComplete(i, #selectedPhotos)
                end

                progressScope:done()
            end)

            -- Save all metadata in a single write access call
            catalog:withWriteAccessDo("Save Llama batch metadata", function()
                for _, result in ipairs(results) do
                    if result.success and result.metadata then
                        local apiResponse = result.metadata
                        local photo = result.photo

                        if settings.generateTitle and apiResponse.title then
                            photo:setRawMetadata("title", apiResponse.title)
                        end
                        if settings.generateCaption and apiResponse.caption then
                            photo:setRawMetadata("caption", apiResponse.caption)
                        end
                        if settings.generateKeywords and apiResponse.keywords then
                            Common.addKeywordsWithParent(catalog, photo, apiResponse.keywords)
                        end
                    end
                end
            end)

            showBatchResults(results)
        end
    end)
end

--------------------------------------------------------------------------------
-- Main entry point
--------------------------------------------------------------------------------

local function main()
    local catalog = LrApplication.activeCatalog()
    local selectedPhotos = catalog:getTargetPhotos()

    if #selectedPhotos == 0 then
        LrDialogs.message("No photos selected", "Please select one or more photos to process.", "critical")
        return
    end

    if #selectedPhotos == 1 then
        local result = LrDialogs.confirm("Single photo selected",
            "You have selected only one photo. Would you like to use the regular Lightroom Llama dialog instead?",
            "Continue with Batch", "Use Regular Dialog", "Cancel")

        if result == "ok" then
            -- Continue with batch processing, fall through to showBatchDialog below
        elseif result == "cancel" then
            -- User chose regular dialog
            LrDialogs.message("Suggestion", "Please use the 'Lightroom Llama...' menu item for single photos.", "info")
            return
        else
            -- Cancel button ("other"), do nothing
            return
        end
    end

    showBatchDialog(selectedPhotos)
end

LrTasks.startAsyncTask(main)
