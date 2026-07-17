--- ResetMetadata.lua — Clear AI-generated metadata from photos.
--- Allows selective reset of title, caption, and keywords (only those under
--- the `llm` parent). Two-step confirmation flow prevents accidental deletion.

local LrApplication = import "LrApplication"
local LrDialogs = import "LrDialogs"
local LrView = import "LrView"
local LrTasks = import "LrTasks"
local LrFunctionContext = import "LrFunctionContext"
local LrBinding = import "LrBinding"
local LrColor = import "LrColor"
local LrPrefs = import "LrPrefs"
local LrPathUtils = import 'LrPathUtils'

-- Load shared utilities
local Common = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "Common.lua"))))()

--------------------------------------------------------------------------------
-- Reset dialog + processing
--------------------------------------------------------------------------------

--- Present a dialog for selecting which metadata to reset, then execute the reset.
--- Two-step confirmation (dialog → explicit confirm) prevents accidental data loss.
--- Settings are persisted via LrPrefs so user choices carry over between sessions.
---@param selectedPhotos table<LrPhoto> Array of selected photos
local function showResetDialog(selectedPhotos)
    local settings = nil

    LrFunctionContext.callWithContext("showResetDialog", function(context)
        local props = LrBinding.makePropertyTable(context)
        local prefs = LrPrefs.prefsForPlugin()

        -- Initialize with default values or saved preferences
        props.resetTitle = prefs.resetTitle ~= false -- Default to true
        props.resetCaption = prefs.resetCaption ~= false -- Default to true
        props.resetKeywords = prefs.resetKeywords ~= false -- Default to true

        local f = LrView.osFactory()

        local c = f:view{
            bind_to_object = props,
            f:column{
                f:static_text{
                    title = string.format("Reset metadata for %d selected photos", #selectedPhotos),
                    font = "<system/bold>"
                },
                f:spacer{height = 20},

                f:static_text{
                    title = "Select which metadata to reset:",
                    font = "<system/bold>"
                },
                f:spacer{height = 15},

                f:checkbox{
                    title = "Reset Titles",
                    value = LrView.bind("resetTitle")
                },
                f:spacer{height = 10},

                f:checkbox{
                    title = "Reset Captions",
                    value = LrView.bind("resetCaption")
                },
                f:spacer{height = 10},

                f:checkbox{
                    title = "Reset LLM Keywords (only removes keywords under 'llm' parent)",
                    value = LrView.bind("resetKeywords")
                },
                f:spacer{height = 20},

                f:separator{width = 400},
                f:spacer{height = 10},

                f:static_text{
                    title = "Warning: This action cannot be undone!",
                    font = "<system/bold>",
                    text_color = LrColor(0.8, 0.2, 0.2)
                },
                f:spacer{height = 10},

                f:static_text{
                    title = "Make sure to backup your catalog before proceeding.",
                    font = "<system>",
                    text_color = LrColor(0.6, 0.6, 0.6)
                }
            }
        }

        local result = LrDialogs.presentModalDialog({
            title = "Reset Metadata",
            contents = c,
            actionVerb = "Reset Metadata",
            cancelVerb = "Cancel"
        })

        if result == "ok" then
            -- Check if at least one option is selected
            if not props.resetTitle and not props.resetCaption and not props.resetKeywords then
                LrDialogs.message("No Selection", "Please select at least one metadata type to reset.", "info")
                return
            end

            -- Save preferences for next time
            prefs.resetTitle = props.resetTitle
            prefs.resetCaption = props.resetCaption
            prefs.resetKeywords = props.resetKeywords

            -- Show final confirmation
            local confirmResult = LrDialogs.confirm(
                "Confirm Reset",
                string.format("Are you sure you want to reset the selected metadata for %d photos? This cannot be undone.", #selectedPhotos),
                "Reset Metadata",
                "Cancel"
            )

            if confirmResult == "ok" then
                settings = {
                    resetTitle = props.resetTitle,
                    resetCaption = props.resetCaption,
                    resetKeywords = props.resetKeywords
                }
            end
        end
    end)

    -- withWriteAccessDo must run outside callWithContext — nesting them can cause
    -- Lightroom SDK to hang. The dialog (inside callWithContext) returns first,
    -- then we perform the catalog mutations here in the outer scope.
    if settings then
        local catalog = LrApplication.activeCatalog()

        -- Reset all metadata in a single write access call
        catalog:withWriteAccessDo("Reset metadata", function()
            for _, photo in ipairs(selectedPhotos) do
                if settings.resetTitle then
                    photo:setRawMetadata("title", "")
                end
                if settings.resetCaption then
                    photo:setRawMetadata("caption", "")
                end
                if settings.resetKeywords then
                    Common.removeLlmKeywords(catalog, photo)
                end
            end
        end)

        -- Show results
        local message = string.format("Reset complete!\n\nProcessed: %d photos", #selectedPhotos)
        LrDialogs.message("Reset Complete", message, "info")
    end
end

--------------------------------------------------------------------------------
-- Main entry point
--------------------------------------------------------------------------------

--- Entry point. Validates that at least one photo is selected, then delegates
--- to showResetDialog.
local function main()
    local catalog = LrApplication.activeCatalog()
    local selectedPhotos = catalog:getTargetPhotos()

    if #selectedPhotos == 0 then
        LrDialogs.message("No photos selected", "Please select one or more photos to reset metadata.", "critical")
        return
    end

    showResetDialog(selectedPhotos)
end

LrTasks.startAsyncTask(main)
