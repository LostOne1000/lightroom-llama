-- Common.lua — Shared utilities for Lightroom Llama plugin
-- Loaded by LrLlama.lua, BatchLrLlama.lua, ResetMetadata.lua

local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local LrLogger = import 'LrLogger'
local LrFileUtils = import 'LrFileUtils'
local LrStringUtils = import 'LrStringUtils'
local LrTasks = import "LrTasks"

local logger = LrLogger('LrLlama')
logger:enable("logfile") -- Logs to ~/Documents/LrClassicLogs | tail -f LrLlama.log

local model = "gemma4:latest"

JSON = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "JSON.lua"))))()

--------------------------------------------------------------------------------
-- Model discovery
--------------------------------------------------------------------------------

local function fetchAvailableModels()
    logger:info("Fetching available models from Ollama")

    local url = "http://localhost:11434/api/tags"
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

--------------------------------------------------------------------------------
-- Thumbnail export
--------------------------------------------------------------------------------

local function exportThumbnail(photo)
    local tempPath = LrFileUtils.chooseUniqueFileName(LrPathUtils.getStandardFilePath('temp') .. "/thumbnail.jpg")
    logger:info("Attempting to export thumbnail to: " .. tempPath)

    -- Check if temp directory is accessible
    local tempDir = LrPathUtils.getStandardFilePath('temp')
    if not LrFileUtils.exists(tempDir) then
        logger:error("Temp directory does not exist: " .. tempDir)
        return nil
    end

    local thumbnailSaved = false
    local success, result = photo:requestJpegThumbnail(512, 512, function(jpegData)
        if jpegData then
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

    if success and thumbnailSaved then
        -- Verify the file was actually created
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
---@param photo LrPhoto The photo to send to the API
---@param prompt string The prompt to send to the API
---@param currentData table (optional) The current title, caption, and keywords of the photo
---@param useCurrentData boolean (optional) Whether to use the current title and caption
---@param useSystemPrompt boolean (optional) Whether to use the system prompt
---@param selectedModel string (optional) The model name to use; falls back to default
---@param systemPrompt string (optional) Custom system prompt; defaults to detailed prompt
---@return table response The response from the API or nil on error
---@return string error Error message or nil on success
--------------------------------------------------------------------------------

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

    local url = "http://localhost:11434/api/generate"

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
        local response_data = JSON:decode(response)
        local rawResponse = response_data.response

        -- Strip markdown code fences (many Ollama models wrap JSON in ```json ... ```)
        rawResponse = string.gsub(rawResponse, "^%s*```%w+\n?", "")
        rawResponse = string.gsub(rawResponse, "\n?```%s*$", "")
        rawResponse = string.gsub(rawResponse, "^%s*```%s*\n?", "")
        rawResponse = string.gsub(rawResponse, "\n?```%s*$", "")

        local response_json = JSON:decode(rawResponse)
        return response_json, nil
    else
        return nil, "Failed to send data to the API"
    end
end

--------------------------------------------------------------------------------
-- Keyword management
--------------------------------------------------------------------------------

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
-- Public API
--------------------------------------------------------------------------------

return {
    model = model,
    fetchAvailableModels = fetchAvailableModels,
    exportThumbnail = exportThumbnail,
    base64EncodeImage = base64EncodeImage,
    sendDataToApi = sendDataToApi,
    addKeywordsWithParent = addKeywordsWithParent,
    getLlmKeywordsFromPhoto = getLlmKeywordsFromPhoto,
    removeLlmKeywords = removeLlmKeywords,
}
