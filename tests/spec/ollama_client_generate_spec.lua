--- ollama_client_generate_spec.lua — Unit tests for OllamaClient.generate() pipeline.
--- Covers success path, retry behavior, error propagation, and temp-file cleanup.

local path = PLUGIN_PATH

--------------------------------------------------------------------------------
--- Helper: build fakes aligned with how OllamaClient calls each dependency.
--- Dot-notation deps get no self; json uses colon so it does.
--------------------------------------------------------------------------------
local function makeFakes()
    local http = {
        post_calls = {},
        post_response = nil,
    }
    http.post = function(url, body, headers)
        table.insert(http.post_calls, { url = url, body = body, headers = headers })
        return http.post_response
    end

    local prefs = {}
    prefs.prefsForPlugin = function()
        return { ollamaServerHost = prefs.ollamaServerHost or "localhost:11434" }
    end

    local tasks = { sleep_calls = {} }
    tasks.sleep = function(seconds)
        table.insert(tasks.sleep_calls, seconds)
    end

    -- JSON uses colon notation (json:encode / json:decode) — self is first arg.
    local json = {
        encode_calls = {},
        encode_return = nil,
    }
    json.encode = function(_, tbl)
        table.insert(json.encode_calls, tbl)
        return json.encode_return or "{}"
    end

    local thumbnailService = {
        export_return = nil,
        encodeBase64_return = nil,
        cleanup_calls = {},
        export_calls = {},
    }
    -- Dot-notation: no implicit self (OllamaClient calls thumbnailService.export(photo))
    thumbnailService.export = function(photo)
        table.insert(thumbnailService.export_calls, photo)
        return thumbnailService.export_return
    end
    thumbnailService.encodeBase64 = function(imagePath)
        return thumbnailService.encodeBase64_return
    end
    thumbnailService.cleanup = function(imagePath)
        table.insert(thumbnailService.cleanup_calls, imagePath)
    end

    local promptBuilder = {
        buildUserPrompt_calls = {},
        assembleRequestBody_calls = {},
        buildUserPrompt_return = "default prompt",
        assembleRequestBody_return = { model = "test", prompt = "p" },
    }
    -- Dot-notation: no implicit self (OllamaClient calls promptBuilder.buildUserPrompt(...))
    promptBuilder.buildUserPrompt = function(instruction, currentData, useCurrent)
        table.insert(promptBuilder.buildUserPrompt_calls, {
            instruction = instruction,
            currentData = currentData,
            useCurrent = useCurrent
        })
        return promptBuilder.buildUserPrompt_return
    end
    promptBuilder.assembleRequestBody = function(userPrompt, model, useSys, override)
        table.insert(promptBuilder.assembleRequestBody_calls, {
            userPrompt = userPrompt,
            model = model,
            useSystemPrompt = useSys,
            systemPromptOverride = override
        })
        return promptBuilder.assembleRequestBody_return
    end

    local responseValidator = {
        validateAndParse_calls = {},
        validateAndParse_metadata = nil,
        validateAndParse_error = nil,
    }
    -- Dot-notation: no implicit self (OllamaClient calls responseValidator.validateAndParse(...))
    responseValidator.validateAndParse = function(rawResponse)
        table.insert(responseValidator.validateAndParse_calls, rawResponse)
        return responseValidator.validateAndParse_metadata,
               responseValidator.validateAndParse_error
    end

    local logger = {
        info_calls = {}, warn_calls = {}, error_calls = {},
        enable = function() end,
    }
    logger.info  = function(msg) table.insert(logger.info_calls, msg) end
    logger.warn  = function(msg) table.insert(logger.warn_calls, msg) end
    logger.error = function(msg) table.insert(logger.error_calls, msg) end

    return {
        http = http,
        prefs = prefs,
        tasks = tasks,
        json = json,
        thumbnailService = thumbnailService,
        promptBuilder = promptBuilder,
        responseValidator = responseValidator,
        logger = logger,
    }
end

--------------------------------------------------------------------------------
describe("OllamaClient — generate()", function()

    --------------------------------------------------------------------
    -- Happy path
    --------------------------------------------------------------------
    describe("success path", function()
        it("orchestrates the full pipeline on first attempt", function()
            local f = makeFakes()
            f.thumbnailService.export_return = "/tmp/thumb.jpg"
            f.thumbnailService.encodeBase64_return = "base64data"
            f.http.post_response = '{"response":"{\"title\":\"T\",\"caption\":\"C\",\"keywords\":[\"k\"]}"}'
            f.responseValidator.validateAndParse_metadata = { title = "T", caption = "C", keywords = { "k" } }
            f.responseValidator.validateAndParse_error = nil

            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)

            local result, err = c.generate(
                { uuid = "photo-1" },   -- photo
                "Caption this",        -- userInstruction
                nil,                   -- currentData
                false,                 -- useCurrentData
                true,                  -- useSystemPrompt
                "gemma4:latest",       -- selectedModel
                nil                    -- systemPromptOverride
            )

            -- Thumbnail exported once
            assert.are_same(1, #f.thumbnailService.export_calls)
            assert.are_same("photo-1", f.thumbnailService.export_calls[1].uuid)

            -- Prompt built with correct args
            assert.are_same(1, #f.promptBuilder.buildUserPrompt_calls)
            local bpCall = f.promptBuilder.buildUserPrompt_calls[1]
            assert.are_same("Caption this", bpCall.instruction)
            assert.is_nil(bpCall.currentData)
            assert.is_false(bpCall.useCurrent)

            -- Request body assembled
            assert.are_same(1, #f.promptBuilder.assembleRequestBody_calls)

            -- Image attached to request body, then encoded + POSTed
            assert.are_same(1, #f.json.encode_calls)
            local encodedBody = f.json.encode_calls[1]
            assert.is_true(type(encodedBody.images) == "table")
            assert.are_same("base64data", encodedBody.images[1])

            -- HTTP POST sent to correct URL
            assert.are_same(1, #f.http.post_calls)
            assert.are_same("http://localhost:11434/api/generate", f.http.post_calls[1].url)

            -- Cleanup always runs
            assert.are_same(1, #f.thumbnailService.cleanup_calls)
            assert.are_same("/tmp/thumb.jpg", f.thumbnailService.cleanup_calls[1])

            -- ResponseValidator called with raw HTTP response
            assert.are_same(1, #f.responseValidator.validateAndParse_calls)

            -- Result from validateAndParse is returned
            assert.are_same("T", result.title)
            assert.is_nil(err)
        end)

        it("falls back to default model when selectedModel is nil", function()
            local f = makeFakes()
            f.thumbnailService.export_return = "/tmp/t.jpg"
            f.thumbnailService.encodeBase64_return = "img"
            f.http.post_response = '{}'

            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)

            c.generate({ uuid = "p" }, "hi", nil, false, true, nil, nil)

            local rbCall = f.promptBuilder.assembleRequestBody_calls[1]
            assert.are_same("gemma4:latest", rbCall.model)
        end)

        it("passes systemPromptOverride through to assembleRequestBody", function()
            local f = makeFakes()
            f.thumbnailService.export_return = "/tmp/t.jpg"
            f.thumbnailService.encodeBase64_return = "img"
            f.http.post_response = '{}'

            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)

            c.generate({ uuid = "p" }, "hi", nil, false, true, "gemma4:latest", "custom system")

            local rbCall = f.promptBuilder.assembleRequestBody_calls[1]
            assert.are_same("custom system", rbCall.systemPromptOverride)
        end)
    end)

    --------------------------------------------------------------------
    -- Thumbnail export retry
    --------------------------------------------------------------------
    describe("thumbnail retry", function()
        it("retries up to 3 times when export fails", function()
            local f = makeFakes()
            -- First two calls return nil, third succeeds
            local attempt = 0
            f.thumbnailService.export = function(photo)
                attempt = attempt + 1
                if attempt < 3 then
                    return nil
                end
                return "/tmp/t.jpg"
            end
            f.thumbnailService.encodeBase64_return = "img"
            f.http.post_response = '{}'

            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)

            c.generate({ uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil)

            assert.are_same(3, attempt)
            -- Sleep called between attempts (2 sleeps for 3 attempts)
            assert.are_same(2, #f.tasks.sleep_calls)
        end)

        it("returns error after 3 failed exports", function()
            local f = makeFakes()
            -- Always return nil from export
            f.thumbnailService.export = function() return nil end

            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)

            local result, err = c.generate(
                { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
            )

            assert.is_nil(result)
            assert.are_same("Failed to export thumbnail after 3 attempts", err)
        end)

        it("sleeps between retry attempts", function()
            local f = makeFakes()
            local attempt = 0
            f.thumbnailService.export = function()
                attempt = attempt + 1
                return nil
            end

            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)

            c.generate({ uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil)

            -- 3 attempts → 3 sleeps (sleep after each failed attempt including last)
            assert.are_same(3, #f.tasks.sleep_calls)
            assert.are_same(0.5, f.tasks.sleep_calls[1])
        end)
    end)

    --------------------------------------------------------------------
    -- Base64 encoding failure
    --------------------------------------------------------------------
    describe("encoding failure", function()
        it("returns error and cleans up when encode fails", function()
            local f = makeFakes()
            f.thumbnailService.export_return = "/tmp/t.jpg"
            f.thumbnailService.encodeBase64_return = nil  -- encoding failed

            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)

            local result, err = c.generate(
                { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
            )

            assert.is_nil(result)
            assert.are_same("Failed to encode image", err)
            -- Cleanup happens even on failure
            assert.are_same(1, #f.thumbnailService.cleanup_calls)
            assert.are_same("/tmp/t.jpg", f.thumbnailService.cleanup_calls[1])
        end)
    end)

    --------------------------------------------------------------------
    -- HTTP POST failure
    --------------------------------------------------------------------
    describe("HTTP failure", function()
        it("returns error when http.post returns nil", function()
            local f = makeFakes()
            f.thumbnailService.export_return = "/tmp/t.jpg"
            f.thumbnailService.encodeBase64_return = "img"
            f.http.post_response = nil  -- network error

            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)

            local result, err = c.generate(
                { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
            )

            assert.is_nil(result)
            assert.are_same("Failed to send data to the API", err)
            -- Cleanup still runs
            assert.are_same(1, #f.thumbnailService.cleanup_calls)
        end)
    end)

    --------------------------------------------------------------------
    -- Response validation delegation
    --------------------------------------------------------------------
    describe("response validation", function()
        it("passes raw HTTP response to validateAndParse", function()
            local f = makeFakes()
            f.thumbnailService.export_return = "/tmp/t.jpg"
            f.thumbnailService.encodeBase64_return = "img"
            f.http.post_response = '{"response":"raw inner"}'

            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)

            c.generate({ uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil)

            assert.are_same(1, #f.responseValidator.validateAndParse_calls)
            assert.are_same('{"response":"raw inner"}', f.responseValidator.validateAndParse_calls[1])
        end)

        it("returns validation error when response is invalid", function()
            local f = makeFakes()
            f.thumbnailService.export_return = "/tmp/t.jpg"
            f.thumbnailService.encodeBase64_return = "img"
            f.http.post_response = 'invalid json'
            f.responseValidator.validateAndParse_metadata = nil
            f.responseValidator.validateAndParse_error = "Bad response"

            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)

            local result, err = c.generate(
                { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
            )

            assert.is_nil(result)
            assert.are_same("Bad response", err)
        end)
    end)

    --------------------------------------------------------------------
    -- Cleanup verification
    --------------------------------------------------------------------
    describe("cleanup", function()
        it("cleans up thumbnail even when HTTP fails", function()
            local f = makeFakes()
            f.thumbnailService.export_return = "/tmp/x.jpg"
            f.thumbnailService.encodeBase64_return = "img"
            f.http.post_response = nil

            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)

            c.generate({ uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil)

            assert.are_same(1, #f.thumbnailService.cleanup_calls)
            assert.are_same("/tmp/x.jpg", f.thumbnailService.cleanup_calls[1])
        end)

        it("cleans up thumbnail even when validation fails", function()
            local f = makeFakes()
            f.thumbnailService.export_return = "/tmp/y.jpg"
            f.thumbnailService.encodeBase64_return = "img"
            f.http.post_response = 'bad'
            f.responseValidator.validateAndParse_metadata = nil
            f.responseValidator.validateAndParse_error = "validation failed"

            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)

            c.generate({ uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil)

            assert.are_same(1, #f.thumbnailService.cleanup_calls)
            assert.are_same("/tmp/y.jpg", f.thumbnailService.cleanup_calls[1])
        end)
    end)

    --------------------------------------------------------------------
    -- Prompt construction
    --------------------------------------------------------------------
    describe("prompt construction", function()
        it("builds prompt with current data when useCurrentData is true", function()
            local f = makeFakes()
            f.thumbnailService.export_return = "/tmp/t.jpg"
            f.thumbnailService.encodeBase64_return = "img"
            f.http.post_response = '{}'

            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)

            c.generate(
                { uuid = "p" },
                "Caption this",
                { title = "Old Title", caption = "Old Caption" },
                true,     -- useCurrentData
                false,
                "gemma4:latest",
                nil
            )

            local bpCall = f.promptBuilder.buildUserPrompt_calls[1]
            assert.is_true(bpCall.useCurrent)
            assert.are_same("Old Title", bpCall.currentData.title)
        end)
    end)
end)
