--- PromptBuilder.lua — Build prompts and request payloads for Ollama API calls.
--- Pure Lua module with no Lightroom SDK dependencies (no LrView, LrDialogs, etc.).
--- Owns all system prompt definitions and user-prompt assembly logic.
--- Loaded by OllamaClient.lua for the generate pipeline and by tests directly.

local prompt = {}

--------------------------------------------------------------------------------
-- System prompts
--------------------------------------------------------------------------------

--- Default system prompt for batch/general mode (the detailed version).
--- Stricter guidelines: 5-12 word titles, 10-30 keywords, quality checklist.
prompt.defaultSystemPrompt = [[# Image Metadata Generation Prompt

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

--- Legacy system prompt for single-photo dialog (more permissive).
--- Allows broader keyword ranges (7-50) and retains existing metadata verbatim.
prompt.singlePhotoSystemPrompt = [[You are an AI tasked with creating a JSON object containing a `title`, a `caption`, and a list of `keywords` based on a given piece of content (such as an image or video). ]] ..
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

--------------------------------------------------------------------------------
-- Prompt assembly
--------------------------------------------------------------------------------

--- Build the user prompt string, optionally prepending current metadata.
--- When `useCurrentData` is true, formats as `"Title: <t> Caption: <c> <instruction>"`
--- to give the model context about existing metadata. Escapes double quotes in
--- title and caption to avoid breaking JSON when this string is embedded in a payload.
---@param userInstruction string The user's custom prompt text (e.g., "Caption this photo")
---@param currentData {title: string, caption: string}|nil Existing metadata
---@param useCurrentData boolean Whether to prepend existing title/caption
---@return string assembled Prompt text ready for the API
function prompt.buildUserPrompt(userInstruction, currentData, useCurrentData)
    if not useCurrentData or not currentData then
        return userInstruction
    end

    local title = (currentData.title or ""):gsub('"', '\\"')
    local caption = (currentData.caption or ""):gsub('"', '\\"')
    return "Title: " .. title .. " Caption: " .. caption .. " " .. userInstruction
end

--- Assemble the full Ollama /api/generate request body fields.
--- Returns a table suitable for JSON:encode before HTTP POST.
--- Does NOT include the `images` field — callers add that after receiving this table.
---@param userPrompt string The assembled user prompt (from buildUserPrompt)
---@param model string Model name to use
---@param useSystemPrompt boolean Whether to include system prompt in request
---@param systemPromptOverride string|nil Custom system prompt, or nil to use default
---@return table requestBody Ready-to-encode POST fields (model, prompt, format, system?, stream)
function prompt.assembleRequestBody(userPrompt, model, useSystemPrompt, systemPromptOverride)
    local activeSystemPrompt = systemPromptOverride or prompt.defaultSystemPrompt

    return {
        model = model,
        prompt = userPrompt,
        format = "json",
        system = useSystemPrompt and activeSystemPrompt or nil,
        stream = false,
    }
end

return prompt
