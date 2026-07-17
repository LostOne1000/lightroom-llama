--- prompt_builder_spec.lua — Unit tests for PromptBuilder.lua
--- Tests user-prompt assembly, request-body construction, and system prompts.

local path = PLUGIN_PATH

describe("PromptBuilder", function()
    local prompt

    before_each(function()
        prompt = assert(loadfile(path .. "PromptBuilder.lua"))()
    end)

    --------------------------------------------------------------------
    -- System prompts exist and are non-empty
    --------------------------------------------------------------------
    describe("system prompts", function()
        it("has a default system prompt", function()
            assert.is_true(#prompt.defaultSystemPrompt > 100)
            assert.is_not_nil(string.find(prompt.defaultSystemPrompt, "title"))
            assert.is_not_nil(string.find(prompt.defaultSystemPrompt, "caption"))
            assert.is_not_nil(string.find(prompt.defaultSystemPrompt, "keywords"))
        end)

        it("has a single-photo system prompt", function()
            assert.is_true(#prompt.singlePhotoSystemPrompt > 50)
        end)

        it("uses different prompts for batch vs single-photo modes", function()
            assert.is_not.equal(
                prompt.defaultSystemPrompt,
                prompt.singlePhotoSystemPrompt
            )
        end)
    end)

    --------------------------------------------------------------------
    -- buildUserPrompt
    --------------------------------------------------------------------
    describe("buildUserPrompt", function()
        it("returns instruction when no current data", function()
            local got = prompt.buildUserPrompt("Caption this photo", nil, false)
            assert.are_same("Caption this photo", got)
        end)

        it("returns instruction when useCurrentData is false", function()
            local got = prompt.buildUserPrompt(
                "Go", { title = "T", caption = "C" }, false
            )
            assert.are_same("Go", got)
        end)

        it("prepends title and caption when useCurrentData is true", function()
            local got = prompt.buildUserPrompt(
                "Update metadata",
                { title = "Sunset", caption = "Golden hour beach" },
                true
            )
            assert.are_same(
                "Title: Sunset Caption: Golden hour beach Update metadata",
                got
            )
        end)

        it("handles empty strings for title/caption", function()
            local got = prompt.buildUserPrompt(
                "Do it",
                { title = "", caption = "" },
                true
            )
            assert.are_same("Title:  Caption:  Do it", got)
        end)

        it("escapes double quotes in title and caption", function()
            local got = prompt.buildUserPrompt(
                "Go",
                { title = 'He said "hi"', caption = 'It\'s "great"' },
                true
            )
            assert.are_same(
                [[Title: He said \"hi\" Caption: It's \"great\" Go]],
                got
            )
        end)

        it("handles nil title or caption gracefully", function()
            local got = prompt.buildUserPrompt(
                "Go",
                { title = nil, caption = "C" },
                true
            )
            assert.are_same("Title:  Caption: C Go", got)
        end)
    end)

    --------------------------------------------------------------------
    -- assembleRequestBody
    --------------------------------------------------------------------
    describe("assembleRequestBody", function()
        it("includes model, prompt, format, and stream fields", function()
            local body = prompt.assembleRequestBody(
                "Caption this", "gemma4:latest", true, nil
            )
            assert.are_same("gemma4:latest", body.model)
            assert.are_same("Caption this", body.prompt)
            assert.are_same("json", body.format)
            assert.is_false(body.stream)
        end)

        it("includes system prompt when useSystemPrompt is true", function()
            local body = prompt.assembleRequestBody(
                "Go", "llama3", true, nil
            )
            assert.is_not_nil(body.system)
            assert.is_same(prompt.defaultSystemPrompt, body.system)
        end)

        it("omits system prompt when useSystemPrompt is false", function()
            local body = prompt.assembleRequestBody(
                "Go", "llama3", false, nil
            )
            assert.is_nil(body.system)
        end)

        it("uses override system prompt when provided", function()
            local custom = "You are a pirate."
            local body = prompt.assembleRequestBody(
                "Arrr", "gemma4:latest", true, custom
            )
            assert.are_same(custom, body.system)
        end)

        it("does not include images field", function()
            local body = prompt.assembleRequestBody(
                "Go", "model", true, nil
            )
            assert.is_nil(body.images)
        end)
    end)
end)
