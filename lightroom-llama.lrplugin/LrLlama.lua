--- LrLlama.lua — Single-photo metadata generation.
--- Invoked from Library or Export menus. Exports a thumbnail, sends it to Ollama,
--- and presents the generated title, caption, and keywords in an editable dialog.

local LrApplication = import "LrApplication"
local LrDialogs = import "LrDialogs"
local LrView = import "LrView"
local LrTasks = import "LrTasks"
local LrFunctionContext = import "LrFunctionContext"
local LrBinding = import "LrBinding"
local LrColor = import "LrColor"
local LrPrefs = import "LrPrefs"
local LrPathUtils = import 'LrPathUtils'

-- Load shared utilities (includes logger, model constant, JSON loader, shared functions)
local Common = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "Common.lua"))))()

--- Legacy system prompt used only by the single-photo dialog.
--- Simpler and more permissive than Common.defaultSystemPrompt — allows broader
--- keyword ranges and retains existing metadata verbatim. Passed to sendDataToApi
--- as the systemPrompt override so single-photo mode differs from batch mode.
local originalSystemPrompt = [[You are an AI tasked with creating a JSON object containing a `title`, a `caption`, and a list of `keywords` based on a given piece of content (such as an image or video). ]] ..
[[The content currently has the following metadata which you need to implement and improve upon. It is important to keep the title and caption as close to this as possible.

Please follow these detailed guidelines for creating excellent metadata:

1. **Title (Description):**
   - Provide a unique, descriptive title for the content.
   - The title should answer the Who, What, When, Where, and Why of the content.
   - It should be written as a sentence or phrase, similar to a news headline, capturing the key details, mood, and emotions of the scene.
   - Do not list keywords in the title. Avoid repetition of words and phrases.
   - Include helpful details such as the angle, focus, and perspective if relevant.
   - Do not include :.
   - If given, use the current title as a starting point.

2. **Caption:**
   - Provide a more detailed description or context for the content. This can be a fuller explanation of the title, including any relevant background or emotional tone that helps convey the essence of the scene.
   - If given, use the current caption as a starting point.

3. **Keywords:**
   - Provide a list of 7 to 50 keywords.
   - Keywords should be specific and directly related to the content.
   - Include broader topics, feelings, concepts, or associations represented by the content.
   - Avoid using unrelated terms or repeating words or compound words.
   - Do not include links, camera information, or trademarks unless required for editorial content.

### JSON Format:
```json
{
  "title": "string",
  "caption": "string",
  "keywords": ["string"]
}
```

### Example:
```json
{
  "title": "A serene sunset over a peaceful beach with golden skies",
  "caption": "A calm evening beach scene with a golden sunset reflecting on the ocean waves, creating a peaceful and tranquil mood. The horizon is clear with soft, pastel colors blending into the blue sky.",
  "keywords": ["sunset", "beach", "calm", "ocean", "serene", "golden skies", "peaceful", "tranquil", "pastel colors", "horizon", "evening"]
}
```

Use this structure and guidelines to generate titles, captions, and keywords that are descriptive, unique, and accurate.]]

-- Note: saveServerAndRefresh moved to Common.lua — used by both dialogs

--- Entry point. Invoked via `LrTasks.startAsyncTask(main)` — required by the
--- Lightroom SDK for menu-activated plugins. Shows a modal dialog that lets the
--- user generate and edit title, caption, and keywords for one photo.
local function main()
    local catalog = LrApplication.activeCatalog()
    local selectedPhotos = catalog:getTargetPhotos()
    if #selectedPhotos == 0 then
        LrDialogs.message("No photo selected", "Please select a photo to view.", "critical")
        return
    end

    -- Single-photo mode only processes the first selection; batch mode handles multiples.
    local selectedPhoto = selectedPhotos[1]
    local thumbnailPath = Common.exportThumbnail(selectedPhoto)

    -- LrBinding requires a live function context for property tables. Without it,
    -- bound UI elements (edit fields, checkboxes, status text) won't update live.
    LrFunctionContext.callWithContext("showLlamaDialog", function(context)
        local props = LrBinding.makePropertyTable(context)
        local prefs = LrPrefs.prefsForPlugin()
        props.status = "Ready"
        props.statusColor = LrColor(0.149, 0.616, 0.412)
        props.prompt = "Caption this photo"
        props.title = selectedPhoto:getFormattedMetadata('title')
        props.caption = selectedPhoto:getFormattedMetadata('caption')
        -- Initialize keywords with existing llm keywords
        local existingLlmKeywords = Common.getLlmKeywordsFromPhoto(selectedPhoto)
        props.keywords = table.concat(existingLlmKeywords, ", ")
        props.response = ""
        -- Pre-check so the "Use current title and caption" checkbox is only enabled
        -- when there's actually existing metadata to include.
        props.useCurrentData = props.title ~= "" or props.caption ~= ""
        props.serverHost = prefs.ollamaServerHost or Common.defaultServerHost
        props.useSystemPrompt = true

        -- Fetch available models from Ollama and populate the dropdown
        local availableModels = Common.fetchAvailableModels()
        props.modelItems = Common.makeModelItems(availableModels)
        props.selectedModel = availableModels[1]  -- default to first available model

        -- Create a view factory
        local f = LrView.osFactory()

        -- Define the dialog contents
        local c = f:view{
            bind_to_object = props,
            f:row{f:column{
                f:picture{
                    value = thumbnailPath,
                    frame_width = 2,
                    width = 400,
                    height = 400
                },
                width = 400
            }, f:spacer{
                width = 10
            }, f:column{
                f:column{f:static_text{
                    title = "Title:"
                }, f:spacer{f:label_spacing{}}, f:edit_field{
                    value = LrView.bind("title"), -- Bind to the new response property
                    width = 400
                }},
                f:spacer{
                    height = 10
                },
                f:static_text{
                    title = "Caption:",
                    alignment = 'left'
                },
                f:spacer{f:label_spacing{}},
                f:edit_field{
                    value = LrView.bind("caption"), -- Bind to the new response property
                    width = 400,
                    height = 100
                },
                f:spacer{
                    height = 10
                },
                f:static_text{
                    title = "Keywords:",
                    alignment = 'left'
                },
                f:spacer{f:label_spacing{}},
                f:edit_field{
                    value = LrView.bind("keywords"),
                    width = 400,
                    height = 60
                },
                f:spacer{
                    height = 10
                },
                f:separator{
                    width = 400
                },
                f:spacer{
                    height = 10
                },
                f:static_text{
                    title = "Prompt:",
                    alignment = 'left'
                },
                f:spacer{f:label_spacing{}},
                f:edit_field{
                    value = LrView.bind("prompt"),
                    width = 400,
                    height = 60
                },
                f:spacer{
                    height = 10
                },
                f:checkbox{
                    title = "Use current title and caption",
                    value = LrView.bind("useCurrentData")
                },
                f:spacer{
                    height = 10
                },
                f:checkbox{
                    title = "Use system prompt",
                    value = LrView.bind("useSystemPrompt")
                },
                f:spacer{
                    height = 10
                },
                f:separator{
                    width = 400
                },
                f:spacer{
                    height = 10
                },
                f:separator{
                    width = 400
                },
                f:spacer{
                    height = 10
                },
                f:static_text{
                    title = "Ollama Server:",
                    alignment = 'left'
                },
                f:spacer{f:label_spacing{}},
                f:edit_field{
                    value = LrView.bind("serverHost"),
                    width = 250,
                },
                f:static_text{
                    title = "(default: localhost:11434)",
                    alignment = 'left',
                    text_color = LrColor(0.6, 0.6, 0.6)
                },
                f:spacer{
                    height = 10
                },
                f:static_text{
                    title = "Model:",
                    alignment = 'left'
                },
                f:spacer{f:label_spacing{}},
                f:popup_menu{
                    value = LrView.bind("selectedModel"),
                    items = LrView.bind("modelItems"),
                    width = 250,
                },
                f:spacer{
                    height = 10
                },
                f:row{f:static_text{
                    fill_horizontal = 1
                }, f:static_text{
                    alignment = 'right',
                    title = LrView.bind("status"),
                    width = 200,
                    font = "<system/bold>",
                    text_color = LrView.bind("statusColor")
                }},
                f:spacer{
                    height = 10
                },
                f:row{f:push_button{
                    title = "Generate",
                    action = function()
                        props.status = "The llama is thinking..."
                        props.statusColor = LrColor(0.439, 0.345, 0.745)

                        -- API call must run off the UI thread. LrBinding properties can
                        -- be mutated from this async callback — they'll propagate live
                        -- to the dialog while we're still inside callWithContext above.
                        LrTasks.startAsyncTask(function()
                            local apiResponse, apiError = Common.sendDataToApi(
                                selectedPhoto,
                                props.prompt,
                                { title = props.title, caption = props.caption },
                                props.useCurrentData,
                                props.useSystemPrompt,
                                props.selectedModel,
                                originalSystemPrompt
                            )
                            if apiError then
                                props.status = "Error: " .. apiError
                                props.statusColor = LrColor(0.8, 0.2, 0.2)
                                return
                            end
                            props.response = apiResponse
                            props.title = apiResponse.title
                            props.caption = apiResponse.caption
                            -- Convert keywords array to comma-separated string for display
                            if apiResponse.keywords and type(apiResponse.keywords) == "table" then
                                props.keywords = table.concat(apiResponse.keywords, ", ")
                            else
                                props.keywords = ""
                            end
                            props.status = "Ready"
                            props.statusColor = LrColor(0.149, 0.616, 0.412)
                        end)
                    end
                }, f:spacer{
                    width = 10
                }, f:push_button{
                    title = "Save Server",
                    -- saveServerAndRefresh must run async so LrBinding picks up modelItems changes
                    action = function()
                        props.status = "Refreshing models..."
                        props.statusColor = LrColor(0.439, 0.345, 0.745)

                        LrTasks.startAsyncTask(function()
                            local ok, msg = Common.saveServerAndRefresh(props, prefs)

                            if not ok then
                                props.status = "Error: " .. msg
                                props.statusColor = LrColor(0.8, 0.2, 0.2)
                            else
                                props.status = msg
                                props.statusColor = LrColor(0.149, 0.616, 0.412)
                            end
                        end)
                    end
                }},
                f:spacer{
                    height = 20
                },
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
            -- Validate and save server host preference
            local ok, validatedHost = Common.validateServerHost(props.serverHost)
            if not ok then
                LrDialogs.message(
                    "Invalid Server Address",
                    validatedHost .. "\n\nPlease enter it as host:port (e.g., localhost:11434 or 192.168.1.10:11434).",
                    "warning"
                )
            else
                prefs.ollamaServerHost = validatedHost
            end

            -- All catalog mutations must run inside withWriteAccessDo — Lightroom
            -- wraps the callback in a transaction and silently discards changes outside it.
            catalog:withWriteAccessDo("Save Llama metadata", function()
                selectedPhoto:setRawMetadata("title", props.title)
                selectedPhoto:setRawMetadata("caption", props.caption)
                -- Parse keywords from comma-separated string and add with llm parent
                if props.keywords and props.keywords ~= "" then
                    local keywordList = {}
                    for keyword in string.gmatch(props.keywords, "([^,]+)") do
                        table.insert(keywordList, keyword:match("^%s*(.-)%s*$")) -- trim whitespace
                    end
                    Common.addKeywordsWithParent(catalog, selectedPhoto, keywordList)
                end
            end)

            LrDialogs.message("Metadata Saved", "Title, caption, and keywords have been saved to the photo.", "info")
        end
    end)
end

LrTasks.startAsyncTask(main)
