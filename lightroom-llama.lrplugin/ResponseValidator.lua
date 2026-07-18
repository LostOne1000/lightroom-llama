--- ResponseValidator.lua — Parse and validate Ollama API responses.
--- Pure Lua module with no Lightroom SDK dependencies. Strips markdown fences,
--- decodes the outer API envelope, and validates the inner JSON schema has
--- title (string), caption (string), and keywords (array of non-empty strings).
--- Loaded by OllamaClient.lua for the generate pipeline and by tests directly.

local LrPathUtils = import 'LrPathUtils'

local JSON = (assert(loadfile(LrPathUtils.child(_PLUGIN.path, "JSON.lua"))))()

local validate = {}

--- Strip markdown code fences from a string.
--- Handles ```json, ```, and bare backtick variants. Two passes ensure both
--- opening and closing fences are removed, including edge cases where the model
--- emits extra whitespace around the blocks.
---@param raw string Raw model response text
---@return string cleaned Text with fences removed
function validate.stripMarkdownFences(raw)
    local result = string.gsub(raw, "^%s*```%w+\n?", "")
    result = string.gsub(result, "\n?```%s*$", "")
    result = string.gsub(result, "^%s*```%s*\n?", "")
    result = string.gsub(result, "\n?```%s*$", "")
    return result
end

--- Decode and validate an Ollama API envelope response.
--- Verifies the outer `{response: "..."}` structure exists. The envelope is the
--- direct JSON output of the `/api/generate` endpoint, which wraps the model's
--- text in a `response` field.
---@param apiResponseString string The raw HTTP response body from /api/generate
---@return table|nil parsed Envelope data (has .response field), or nil
---@return string|nil err Error message or nil
function validate.parseApiEnvelope(apiResponseString)
    local decodeOk, data = pcall(function()
        return JSON:decode(apiResponseString)
    end)

    if not decodeOk
        or type(data) ~= "table"
        or type(data.response) ~= "string" then
        return nil, "Invalid API response structure"
    end

    return data, nil
end

--- Validate that a decoded JSON object has the required metadata schema.
--- Checks for title (string), caption (string), keywords (array of non-empty strings).
---@param data table Decoded JSON object from the model
---@return bool ok True if schema is valid
---@return string|nil err Describes which field failed, or nil
function validate.checkMetadataSchema(data)
    if type(data.title) ~= "string"
        or type(data.caption) ~= "string"
        or type(data.keywords) ~= "table" then
        return false, "API response missing required fields (title, caption, keywords)"
    end

    for _, kw in ipairs(data.keywords) do
        if type(kw) ~= "string" or kw:match("^%s*$") then
            return false, "API response contains an invalid keyword"
        end
    end

    return true, nil
end

--- Full pipeline: parse envelope, strip fences, decode inner JSON, validate schema.
--- Accepts the raw HTTP response string and returns parsed metadata or an error.
---@param rawHttpResponse string Raw POST /api/generate response body
---@return table|nil metadata {title, caption, keywords} on success
---@return string|nil err Error message, or nil
function validate.validateAndParse(rawHttpResponse)
    -- Parse outer Ollama API envelope
    local envelope, err = validate.parseApiEnvelope(rawHttpResponse)
    if not envelope then
        return nil, err
    end

    local rawResponse = envelope.response

    -- Many Ollama models emit markdown-wrapped JSON ("```json\n{...}\n```").
    -- Strip the fences so JSON:decode receives bare JSON.
    rawResponse = validate.stripMarkdownFences(rawResponse)

    -- Decode the model-generated JSON
    local decodeOk, responseJson = pcall(function()
        return JSON:decode(rawResponse)
    end)

    if not decodeOk or type(responseJson) ~= "table" then
        return nil, "Invalid JSON in API response"
    end

    -- Validate required fields exist with correct types
    local schemaOk, schemaErr = validate.checkMetadataSchema(responseJson)
    if not schemaOk then
        return nil, schemaErr
    end

    return responseJson, nil
end

return validate
