--- LlamaDialog.lua — Lightroom view adapter for single-photo metadata generation.
--- Owns all LrView / LrBinding / LrDialogs construction: property table, UI layout,
--- button actions, and modal presentation. Delegates workflow logic to the injected
--- controller so that business rules are testable without Lightroom.

local LrDialogs = import "LrDialogs"
local LrView    = import "LrView"
local LrTasks   = import "LrTasks"
local LrFunctionContext = import "LrFunctionContext"
local LrBinding = import "LrBinding"
local LrColor   = import "LrColor"
local LrPathUtils = import 'LrPathUtils'

--- Map semantic status kinds to Lightroom display colors.
local STATUS_COLORS = {
    success = LrColor(0.149, 0.616, 0.412), -- green
    working = LrColor(0.439, 0.345, 0.745), -- purple
    error   = LrColor(0.8, 0.2, 0.2),       -- red
}

--------------------------------------------------------------------------------
--- Build and show the modal dialog.
---@param deps table Dependency map:
---   { client, common, promptBuilder, prefs, catalog, photo, thumbnailPath,
---     statusMessages, writeMetadata }
---   `writeMetadata` wraps catalog:withWriteAccessDo for the save flow.
--------------------------------------------------------------------------------
local function show(deps)
    local ControllerModule =
        assert(loadfile(LrPathUtils.child(_PLUGIN.path, "SinglePhotoController.lua")))()
    local controller = ControllerModule.new(deps)

    LrFunctionContext.callWithContext("showLlamaDialog", function(context)
        local props = LrBinding.makePropertyTable(context)

        -- Populate binding table from controller initial state. The same table
        -- is passed back to controller actions so they mutate the live bindings.
        local initialState = controller.initState()
        for k, v in pairs(initialState) do
            props[k] = v
        end

        -- Create a view factory
        local f = LrView.osFactory()

        -- Define the dialog contents (preserving exact current layout and sizing)
        local c = f:view{
            bind_to_object = props,
            f:row{f:column{
                f:picture{
                    value = deps.thumbnailPath,
                    frame_width = 2,
                    width = 400,
                    height = 400
                },
                width = 400
            }, f:spacer{ width = 10 }, f:column{

                -- Title field
                f:column{f:static_text{ title = "Title:" },
                    f:spacer{ f:label_spacing{} },
                    f:edit_field{ value = LrView.bind("title"), width = 400 }},
                f:spacer{ height = 10 },

                -- Caption field
                f:static_text{ title = "Caption:", alignment = 'left' },
                f:spacer{ f:label_spacing{} },
                f:edit_field{ value = LrView.bind("caption"), width = 400, height = 100 },
                f:spacer{ height = 10 },

                -- Keywords field
                f:static_text{ title = "Keywords:", alignment = 'left' },
                f:spacer{ f:label_spacing{} },
                f:edit_field{ value = LrView.bind("keywords"), width = 400, height = 60 },
                f:spacer{ height = 10 },

                f:separator{ width = 400 },
                f:spacer{ height = 10 },

                -- Prompt field
                f:static_text{ title = "Prompt:", alignment = 'left' },
                f:spacer{ f:label_spacing{} },
                f:edit_field{ value = LrView.bind("prompt"), width = 400, height = 60 },
                f:spacer{ height = 10 },

                -- Checkboxes
                f:checkbox{ title = "Use current title and caption",
                    value = LrView.bind("useCurrentData") },
                f:spacer{ height = 10 },
                f:checkbox{ title = "Use system prompt",
                    value = LrView.bind("useSystemPrompt") },
                f:spacer{ height = 10 },

                f:separator{ width = 400 },
                f:spacer{ height = 10 },
                f:separator{ width = 400 },
                f:spacer{ height = 10 },

                -- Server host
                f:static_text{ title = "Ollama Server:", alignment = 'left' },
                f:spacer{ f:label_spacing{} },
                f:edit_field{ value = LrView.bind("serverHost"), width = 250 },
                f:static_text{ title = "(default: localhost:11434)",
                    alignment = 'left', text_color = LrColor(0.6, 0.6, 0.6) },
                f:spacer{ height = 10 },

                -- Model dropdown
                f:static_text{ title = "Model:", alignment = 'left' },
                f:spacer{ f:label_spacing{} },
                f:popup_menu{
                    value = LrView.bind("selectedModel"),
                    items = LrView.bind("modelItems"),
                    width = 250,
                },
                f:spacer{ height = 10 },

                -- Status text with dynamic color
                f:row{f:static_text{ fill_horizontal = 1 },
                    f:static_text{
                        alignment = 'right',
                        title = LrView.bind("status"),
                        width = 200,
                        font = "<system/bold>",
                        text_color = LrView.bind("statusColor")
                    }},
                f:spacer{ height = 10 },

                -- Action buttons
                f:row{
                    f:push_button{
                        title = "Generate",
                        action = function()
                            LrTasks.startAsyncTask(function()
                                controller.generate(props)
                                props.statusColor = STATUS_COLORS[props.statusKind]
                                    or STATUS_COLORS.success
                            end)
                        end
                    },
                    f:spacer{ width = 10 },
                    f:push_button{
                        title = "Save Server",
                        action = function()
                            LrTasks.startAsyncTask(function()
                                controller.saveServer(props)
                                props.statusColor = STATUS_COLORS[props.statusKind]
                                    or STATUS_COLORS.success
                            end)
                        end
                    }},
                f:spacer{ height = 20 },

                width = 400
            }}
        }

        -- Show the dialog
        local result = LrDialogs.presentModalDialog({
            title = "Lightroom Llama",
            contents = c,
            actionVerb = "Save"
        })

        if result == "ok" then
            local saveResult = controller.saveMetadata(props)

            if not saveResult.ok then
                -- Validation failure — show error; controller did NOT write prefs/data
                LrDialogs.message(
                    "Invalid Server Address",
                    saveResult.message
                        .. "\n\nPlease enter it as host:port (e.g., localhost:11434 or 192.168.1.10:11434).",
                    "warning"
                )
            else
                LrDialogs.message(
                    "Metadata Saved",
                    "Title, caption, and keywords have been saved to the photo.",
                    "info"
                )
            end
        end
    end)
end

return { show = show }
