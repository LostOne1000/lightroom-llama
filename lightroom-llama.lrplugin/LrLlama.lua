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

-- The original system prompt from LrLlama.lua (preserved for single-image use)
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

local function main()
    -- Get the active catalog
    local catalog = LrApplication.activeCatalog()

    -- Get the selected photo
    local selectedPhotos = catalog:getTargetPhotos() -- Gets all selected photos
    if #selectedPhotos == 0 then
        LrDialogs.message("No photo selected", "Please select a photo to view.", "critical")
        return
    end

    -- Get the first selected photo (if multiple, you can modify the code for more)
    local selectedPhoto = selectedPhotos[1]
    local thumbnailPath = Common.exportThumbnail(selectedPhoto)

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

            -- Save the metadata to the photo
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
