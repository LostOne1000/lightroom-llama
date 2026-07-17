--- response_validator_spec.lua — Unit tests for ResponseValidator.lua
--- Tests fence stripping, envelope parsing, schema validation, and the full pipeline.

local path = PLUGIN_PATH

describe("ResponseValidator", function()
    local validate

    before_each(function()
        -- Reload fresh each time so cached JSON state doesn't leak between tests
        validate = assert(loadfile(path .. "ResponseValidator.lua"))()
    end)

    --------------------------------------------------------------------
    -- stripMarkdownFences
    --------------------------------------------------------------------
    describe("stripMarkdownFences", function()
        it("returns bare JSON unchanged", function()
            local json = '{"title":"A","caption":"B","keywords":["c"]}'
            assert.are.same(json, validate.stripMarkdownFences(json))
        end)

        it("strips ```json ... ``` fences", function()
            local raw = "```json\n{\"title\":\"A\"}\n```"
            local got = validate.stripMarkdownFences(raw)
            assert.are_same('{"title":"A"}', got)
        end)

        it("strips bare ``` fences without language tag", function()
            local raw = "```\n{}\n```"
            local got = validate.stripMarkdownFences(raw)
            assert.are_same('{}', got)
        end)

        it("handles leading/trailing whitespace around fences", function()
            local raw = "  ```json\n{\"x\":1}\n```  "
            local got = validate.stripMarkdownFences(raw)
            assert.are_same('{"x":1}', got)
        end)
    end)

    --------------------------------------------------------------------
    -- parseApiEnvelope
    --------------------------------------------------------------------
    describe("parseApiEnvelope", function()
        it("decodes a valid envelope with response field", function()
            local envelope = '{"response":"hello world"}'
            local data, err = validate.parseApiEnvelope(envelope)
            assert.falsy(err)
            assert.are_same("hello world", data.response)
        end)

        it("rejects malformed JSON", function()
            local data, err = validate.parseApiEnvelope("{bad json")
            assert.falsy(data)
            assert.is_not_nil(err)
        end)

        it("rejects an envelope missing the response field", function()
            local data, err = validate.parseApiEnvelope('{"foo":1}')
            assert.falsy(data)
            assert.is_not_nil(err)
        end)
    end)

    --------------------------------------------------------------------
    -- checkMetadataSchema
    --------------------------------------------------------------------
    describe("checkMetadataSchema", function()
        it("accepts valid title, caption, keywords", function()
            local ok, err = validate.checkMetadataSchema({
                title = "Sunset over ocean",
                caption = "A beautiful scene",
                keywords = { "ocean", "sunset" },
            })
            assert.is_true(ok)
            assert.falsy(err)
        end)

        it("rejects missing title", function()
            local ok, err = validate.checkMetadataSchema({
                caption = "ok", keywords = { "a" }
            })
            assert.is_false(ok)
            assert.is_not_nil(err)
        end)

        it("rejects empty keyword string in array", function()
            local ok, err = validate.checkMetadataSchema({
                title = "T", caption = "C", keywords = { "", "b" }
            })
            assert.is_false(ok)
            assert.is_not_nil(err)
        end)

        it("rejects whitespace-only keyword", function()
            local ok, err = validate.checkMetadataSchema({
                title = "T", caption = "C", keywords = { "   ", "b" }
            })
            assert.is_false(ok)
        end)
    end)

    --------------------------------------------------------------------
    -- validateAndParse (full pipeline)
    --------------------------------------------------------------------
    describe("validateAndParse", function()
        local function makeEnvelope(innerJson)
            -- Build a proper outer envelope string. The JSON.lua decoder is
            --- available via _PLUGIN + LrPathUtils, but simpler to inline.
            return '{"response":' .. innerJson .. '}'
        end

        it("returns parsed metadata for clean JSON response", function()
            local inner = [[{"title":"Beach sunset","caption":"Waves roll in","keywords":["beach","sunset"]}]]
            -- Need to escape quotes for embedding inside the envelope JSON string
            local envelope = '{"response":' .. '"' .. string.gsub(inner, '"', '\\"') .. '"}'
            local metadata, err = validate.validateAndParse(envelope)
            assert.falsy(err)
            assert.are_same("Beach sunset", metadata.title)
        end)

        it("handles markdown-fenced inner JSON", function()
            -- Build: {"response": "```json\n{...}\n```"}
            local fenced = '```json\n{"title":"X","caption":"Y","keywords":["z"]}\n```'
            local escaped = string.gsub(fenced, '"', '\\"')
            local envelope = '{"response":"' .. escaped .. '"}'
            local metadata, err = validate.validateAndParse(envelope)
            assert.falsy(err)
            assert.are_same("X", metadata.title)
        end)

        it("returns error for non-json response body", function()
            local envelope = '{"response":"just plain text"}'
            local metadata, err = validate.validateAndParse(envelope)
            assert.falsy(metadata)
            assert.is_not_nil(err)
        end)

        it("returns error when envelope is invalid", function()
            local metadata, err = validate.validateAndParse("not json at all")
            assert.falsy(metadata)
            assert.is_not_nil(err)
        end)
    end)
end)
