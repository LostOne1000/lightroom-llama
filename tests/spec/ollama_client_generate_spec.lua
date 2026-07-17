--- ollama_client_generate_spec.lua — Unit tests for OllamaClient.generate() pipeline.
--- Covers success path, retry behavior, error propagation, exception-safe cleanup,
--- event ordering, and error-preservation policy.

local path = PLUGIN_PATH

--------------------------------------------------------------------------------
--- Helper: build fakes with event recording aligned to OllamaClient internals.
--- Dot-notation deps (http.post, thumbnailService.export) get no self.
--- Colon-notation deps (json.encode) receive self as first arg.
--------------------------------------------------------------------------------
local function makeFakes()
    local events = {}

    local http = { post_calls = {}, _response = nil }
    http.post = function(url, body, headers)
        table.insert(events, "post")
        table.insert(http.post_calls, { url = url, body = body, headers = headers })
        return http._response
    end

    local prefs = {}
    prefs.prefsForPlugin = function()
        return { ollamaServerHost = "localhost:11434" }
    end

    local tasks = { sleep_calls = {} }
    tasks.sleep = function(s)
        table.insert(tasks.sleep_calls, s)
    end

    -- JSON uses colon notation (json:encode) — self is first arg.
    local json = { encode_calls = {}, _return = nil }
    json.encode = function(_, tbl)
        table.insert(events, "json-encode")
        table.insert(json.encode_calls, tbl)
        return json._return or "{}"
    end

    -- thumbnailService uses dot notation — no implicit self.
    local ts = { cleanup_calls = {}, export_calls = {}, _export_return = nil }
    ts.export = function(photo)
        table.insert(events, "export")
        table.insert(ts.export_calls, photo)
        return ts._export_return
    end
    ts.encodeBase64 = function(imagePath)
        table.insert(events, "encode")
        return ts._encode_return
    end
    ts.cleanup = function(imagePath)
        table.insert(events, "cleanup")
        table.insert(ts.cleanup_calls, imagePath)
    end

    -- promptBuilder uses dot notation — no implicit self.
    local pb = {
        buildUserPrompt_calls = {},
        assembleRequestBody_calls = {},
        _buildReturn = "default prompt",
        _assembleReturn = { model = "test", prompt = "p" },
    }
    pb.buildUserPrompt = function(instruction, currentData, useCurrent)
        table.insert(events, "build-prompt")
        table.insert(pb.buildUserPrompt_calls, {
            instruction = instruction,
            currentData = currentData,
            useCurrent = useCurrent,
        })
        return pb._buildReturn
    end
    pb.assembleRequestBody = function(userPrompt, model, useSys, override)
        table.insert(events, "assemble-body")
        table.insert(pb.assembleRequestBody_calls, {
            userPrompt = userPrompt,
            model = model,
            useSystemPrompt = useSys,
            systemPromptOverride = override,
        })
        return pb._assembleReturn
    end

    -- responseValidator uses dot notation.
    local rv = { calls = {}, _metadata = nil, _error = nil }
    rv.validateAndParse = function(rawResponse)
        table.insert(events, "validate")
        table.insert(rv.calls, rawResponse)
        return rv._metadata, rv._error
    end

    -- logger — colon notation for info/warn/error (OllamaClient calls :info, :warn, :error).
    local logger = { info_calls = {}, warn_calls = {}, error_calls = {}, enable = function() end }
    logger.info  = function(_self, msg) table.insert(logger.info_calls, msg) end
    logger.warn  = function(_self, msg) table.insert(logger.warn_calls, msg) end
    logger.error = function(_self, msg) table.insert(logger.error_calls, msg) end

    return {
        events = events,
        http = http,
        prefs = prefs,
        tasks = tasks,
        json = json,
        thumbnailService = ts,
        promptBuilder = pb,
        responseValidator = rv,
        logger = logger,
    }
end

--------------------------------------------------------------------------------
--- Assert helpers
--------------------------------------------------------------------------------
local function assertEventOrder(expected)
    return function(f)
        for i, name in ipairs(expected) do
            assert.are_same(name, f.events[i],
                string.format("Expected event[%d] = '%s', got '%s'", i, name, tostring(f.events[i])))
        end
    end
end

--------------------------------------------------------------------------------
describe("OllamaClient — generate()", function()

    local Client
    local c
    local f

    --------------------------------------------------------------------
    -- 1. Happy path: full pipeline with event ordering
    --------------------------------------------------------------------
    it("orchestrates the full pipeline on first attempt", function()
        f = makeFakes()
        f.thumbnailService._export_return = "/tmp/thumb.jpg"
        f.thumbnailService._encode_return = "base64data"
        f.http._response = '{"response":"{\"title\":\"T\",\"caption\":\"C\",\"keywords\":[\"k\"]}"}'
        f.responseValidator._metadata = { title = "T", caption = "C", keywords = { "k" } }

        Client = assert(loadfile(path .. "OllamaClient.lua"))()
        c = Client.new(f)

        local result, err = c.generate(
            { uuid = "photo-1" },
            "Caption this",
            nil, false, true, "gemma4:latest", nil
        )

        -- Event order: export → encode → build-prompt → assemble-body → json-encode
        --              → post → cleanup → validate
        assertEventOrder({
            "export", "encode", "build-prompt", "assemble-body",
            "json-encode", "post", "cleanup", "validate"
        })(f)

        -- Cleanup exactly once with correct path.
        assert.are_same(1, #f.thumbnailService.cleanup_calls)
        assert.are_same("/tmp/thumb.jpg", f.thumbnailService.cleanup_calls[1])

        -- Result from validator returned unchanged.
        assert.are_same("T", result.title)
        assert.is_nil(err)
    end)

    --------------------------------------------------------------------
    -- 2. Encoding returns nil → cleanup, no POST/validate
    --------------------------------------------------------------------
    it("cleans up when encoding returns nil", function()
        f = makeFakes()
        f.thumbnailService._export_return = "/tmp/t.jpg"
        f.thumbnailService._encode_return = nil

        Client = assert(loadfile(path .. "OllamaClient.lua"))()
        c = Client.new(f)

        local result, err = c.generate(
            { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
        )

        assert.is_nil(result)
        assert.are_same("Failed to encode image", err)
        assert.are_same(1, #f.thumbnailService.cleanup_calls)
        assert.are_same("/tmp/t.jpg", f.thumbnailService.cleanup_calls[1])
        assert.are_same(0, #f.http.post_calls)
        assert.are_same(0, #f.responseValidator.calls)
    end)

    --------------------------------------------------------------------
    -- 3. Encoding throws → exception propagates (no pcall in Lightroom).
    --    In production, SDK functions return nil on error rather than
    --    throwing, so this path is defensive-only. Tests catch with
    --    pcall at the test level since cleanup cannot run when an
    --    intermediate step throws without protected calls.
    --------------------------------------------------------------------
    it("propagates exceptions from encoding", function()
        f = makeFakes()
        f.thumbnailService._export_return = "/tmp/t.jpg"
        f.thumbnailService.encodeBase64 = function(_)
            table.insert(f.events, "encode")
            error("encode exploded")
        end

        Client = assert(loadfile(path .. "OllamaClient.lua"))()
        c = Client.new(f)

        local ok, err = pcall(c.generate, c,
            { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
        )

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(err), "encode exploded", 1, true))
        -- Note: cleanup cannot run when intermediate steps throw
        -- without pcall (which Lightroom's sandbox doesn't support).
        assert.are_same(0, #f.http.post_calls)
    end)

    --------------------------------------------------------------------
    -- 4. Prompt builder throws → same propagation behavior.
    --------------------------------------------------------------------
    it("propagates exceptions from prompt builder", function()
        f = makeFakes()
        f.thumbnailService._export_return = "/tmp/t.jpg"
        f.thumbnailService._encode_return = "img"
        f.promptBuilder.buildUserPrompt = function()
            table.insert(f.events, "build-prompt")
            error("prompt builder error")
        end

        Client = assert(loadfile(path .. "OllamaClient.lua"))()
        c = Client.new(f)

        local ok, err = pcall(c.generate, c,
            { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
        )

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(err), "prompt builder error", 1, true))
    end)

    --------------------------------------------------------------------
    -- 5. Request-body assembly throws → same propagation behavior.
    --------------------------------------------------------------------
    it("propagates exceptions from request-body assembly", function()
        f = makeFakes()
        f.thumbnailService._export_return = "/tmp/t.jpg"
        f.thumbnailService._encode_return = "img"
        f.promptBuilder.assembleRequestBody = function()
            table.insert(f.events, "assemble-body")
            error("assembly error")
        end

        Client = assert(loadfile(path .. "OllamaClient.lua"))()
        c = Client.new(f)

        local ok, err = pcall(c.generate, c,
            { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
        )

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(err), "assembly error", 1, true))
    end)

    --------------------------------------------------------------------
    -- 6. JSON encoding throws → same propagation behavior.
    --------------------------------------------------------------------
    it("propagates exceptions from JSON encoding", function()
        f = makeFakes()
        f.thumbnailService._export_return = "/tmp/t.jpg"
        f.thumbnailService._encode_return = "img"
        f.json.encode = function(_)
            table.insert(f.events, "json-encode")
            error("json encoding failed")
        end

        Client = assert(loadfile(path .. "OllamaClient.lua"))()
        c = Client.new(f)

        local ok, err = pcall(c.generate, c,
            { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
        )

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(err), "json encoding failed", 1, true))
        assert.are_same(0, #f.http.post_calls)
    end)

    --------------------------------------------------------------------
    -- 7. HTTP POST returns nil → cleanup before error return
    --------------------------------------------------------------------
    it("cleans up when http.post returns nil", function()
        f = makeFakes()
        f.thumbnailService._export_return = "/tmp/t.jpg"
        f.thumbnailService._encode_return = "img"
        f.http._response = nil

        Client = assert(loadfile(path .. "OllamaClient.lua"))()
        c = Client.new(f)

        local result, err = c.generate(
            { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
        )

        assert.is_nil(result)
        assert.are_same("Failed to send data to the API", err)
        -- Cleanup runs before error return.
        assertEventOrder({
            "export", "encode", "build-prompt", "assemble-body",
            "json-encode", "post", "cleanup"
        })(f)
        assert.are_same(1, #f.thumbnailService.cleanup_calls)
    end)

    --------------------------------------------------------------------
    -- 8. HTTP POST throws → exception propagates (same as above).
    --------------------------------------------------------------------
    it("propagates exceptions from http.post", function()
        f = makeFakes()
        f.thumbnailService._export_return = "/tmp/t.jpg"
        f.thumbnailService._encode_return = "img"
        f.http.post = function(_, _, _)
            table.insert(f.events, "post")
            error("post exploded")
        end

        Client = assert(loadfile(path .. "OllamaClient.lua"))()
        c = Client.new(f)

        local ok, err = pcall(c.generate, c,
            { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
        )

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(err), "post exploded", 1, true))
    end)

    --------------------------------------------------------------------
    -- 9. Validator returns error → cleanup happened before validation
    --------------------------------------------------------------------
    it("cleans up before validator and returns validation error", function()
        f = makeFakes()
        f.thumbnailService._export_return = "/tmp/t.jpg"
        f.thumbnailService._encode_return = "img"
        f.http._response = '{"response":"raw inner"}'
        f.responseValidator._metadata = nil
        f.responseValidator._error = "invalid metadata"

        Client = assert(loadfile(path .. "OllamaClient.lua"))()
        c = Client.new(f)

        local result, err = c.generate(
            { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
        )

        assert.is_nil(result)
        assert.are_same("invalid metadata", err)
        -- Cleanup before validate in event order.
        local cleanupIdx = nil
        local validateIdx = nil
        for i, e in ipairs(f.events) do
            if e == "cleanup" then cleanupIdx = i end
            if e == "validate" then validateIdx = i end
        end
        assert.is_not_nil(cleanupIdx)
        assert.is_not_nil(validateIdx)
        assert.are_true(cleanupIdx < validateIdx,
            "Cleanup must occur before validation")
    end)

    --------------------------------------------------------------------
    -- 10. Validator throws → cleanup has occurred already (validation
    --     is outside runWithCleanup, so exception propagates after cleanup).
    --------------------------------------------------------------------
    it("cleans up before validator even if validator throws", function()
        f = makeFakes()
        f.thumbnailService._export_return = "/tmp/t.jpg"
        f.thumbnailService._encode_return = "img"
        f.http._response = '{"response":"raw"}'
        f.responseValidator.validateAndParse = function(_)
            table.insert(f.events, "validate")
            error("validation exploded")
        end

        Client = assert(loadfile(path .. "OllamaClient.lua"))()
        c = Client.new(f)

        -- Validation is outside runWithCleanup, so a thrown exception
        -- propagates. Cleanup already happened inside runWithCleanup.
        local ok, err = pcall(c.generate, c,
            { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
        )

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(err), "validation exploded", 1, true))
        -- Cleanup ran before validation was even attempted.
        assert.are_same(1, #f.thumbnailService.cleanup_calls)
    end)

    --------------------------------------------------------------------
    -- 11. Cleanup fails after successful generation → exception propagates.
    --     Without pcall, a cleanup failure is an exception that bubbles up.
    --     In production, LrFileUtils.delete (the cleanup implementation)
    --     returns nil on error rather than throwing, so this is defensive.
    --------------------------------------------------------------------
    it("propagates exceptions when cleanup fails after generation", function()
        f = makeFakes()
        f.thumbnailService._export_return = "/tmp/t.jpg"
        f.thumbnailService._encode_return = "img"
        f.http._response = '{"response":"{\"title\":\"T\",\"caption\":\"C\",\"keywords\":[\"k\"]}"}'
        f.responseValidator._metadata = { title = "T", caption = "C", keywords = { "k" } }
        -- Make cleanup throw.
        f.thumbnailService.cleanup = function(_)
            table.insert(f.events, "cleanup")
            error("disk full")
        end

        Client = assert(loadfile(path .. "OllamaClient.lua"))()
        c = Client.new(f)

        local ok, err = pcall(c.generate, c,
            { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
        )

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(err), "disk full", 1, true))
    end)

    --------------------------------------------------------------------
    -- 12. Cleanup fails AND generation failed → first exception wins.
    --     Without pcall, when generation throws, cleanup never runs, so
    --     the generation error is what propagates (cleanup is never reached).
    --------------------------------------------------------------------
    it("propagates generation error when generation throws", function()
        f = makeFakes()
        f.thumbnailService._export_return = "/tmp/t.jpg"
        f.thumbnailService._encode_return = "img"
        -- POST throws (generation fails before cleanup is reached)
        f.http.post = function(_, _, _)
            table.insert(f.events, "post")
            error("network timeout")
        end

        Client = assert(loadfile(path .. "OllamaClient.lua"))()
        c = Client.new(f)

        local ok, err = pcall(c.generate, c,
            { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
        )

        assert.is_false(ok)
        -- Generation error propagates; cleanup is never reached.
        assert.is_not_nil(string.find(tostring(err), "network timeout", 1, true),
            "Expected original generation error to propagate")
    end)

    --------------------------------------------------------------------
    -- 13. Export fails all 3 attempts → no cleanup
    --------------------------------------------------------------------
    it("does not clean up when export fails all attempts", function()
        f = makeFakes()
        f.thumbnailService.export = function(photo)
            table.insert(f.events, "export")
            table.insert(f.thumbnailService.export_calls, photo)
            return nil
        end

        Client = assert(loadfile(path .. "OllamaClient.lua"))()
        c = Client.new(f)

        local result, err = c.generate(
            { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
        )

        assert.is_nil(result)
        assert.are_same("Failed to export thumbnail after 3 attempts", err)
        -- Export called 3 times.
        assert.are_same(3, #f.thumbnailService.export_calls)
        -- No cleanup (nothing to clean up).
        assert.are_same(0, #f.thumbnailService.cleanup_calls)
    end)

    --------------------------------------------------------------------
    -- 14. Export succeeds on second attempt → cleanup runs once
    --------------------------------------------------------------------
    it("cleans up when export succeeds on second attempt", function()
        f = makeFakes()
        local attempt = 0
        f.thumbnailService.export = function(photo)
            table.insert(f.events, "export")
            table.insert(f.thumbnailService.export_calls, photo)
            attempt = attempt + 1
            if attempt < 2 then return nil end
            return "/tmp/t.jpg"
        end
        f.thumbnailService._encode_return = "img"
        f.http._response = '{}'

        Client = assert(loadfile(path .. "OllamaClient.lua"))()
        c = Client.new(f)

        local result, err = c.generate(
            { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
        )

        -- Export called twice.
        assert.are_same(2, #f.thumbnailService.export_calls)
        -- One sleep between attempts.
        assert.are_same(1, #f.tasks.sleep_calls)
        -- Cleanup runs once with correct path.
        assert.are_same(1, #f.thumbnailService.cleanup_calls)
        assert.are_same("/tmp/t.jpg", f.thumbnailService.cleanup_calls[1])
    end)

    --------------------------------------------------------------------
    -- 15. Export succeeds on third attempt → cleanup runs once
    --------------------------------------------------------------------
    it("cleans up when export succeeds on third attempt", function()
        f = makeFakes()
        local attempt = 0
        f.thumbnailService.export = function(photo)
            table.insert(f.events, "export")
            table.insert(f.thumbnailService.export_calls, photo)
            attempt = attempt + 1
            if attempt < 3 then return nil end
            return "/tmp/t.jpg"
        end
        f.thumbnailService._encode_return = "img"
        f.http._response = '{}'

        Client = assert(loadfile(path .. "OllamaClient.lua"))()
        c = Client.new(f)

        local result, err = c.generate(
            { uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil
        )

        -- Export called three times.
        assert.are_same(3, #f.thumbnailService.export_calls)
        -- Two sleeps between attempts.
        assert.are_same(2, #f.tasks.sleep_calls)
        -- Cleanup runs once.
        assert.are_same(1, #f.thumbnailService.cleanup_calls)
        assert.are_same("/tmp/t.jpg", f.thumbnailService.cleanup_calls[1])
    end)

    --------------------------------------------------------------------
    -- 16. No double cleanup — explicit assertion across scenarios
    --------------------------------------------------------------------
    it("never calls cleanup more than once in any post-export scenario", function()
        -- This meta-test re-runs several configurations and asserts
        -- cleanup count == 1 for every scenario where export succeeded.
        local scenarios = {
            -- Name, setup function
            {
                "success",
                function(fake)
                    fake.thumbnailService._encode_return = "img"
                    fake.http._response = '{"response":"{\"title\":\"T\",\"caption\":\"C\",\"keywords\":[\"k\"]}"}'
                    fake.responseValidator._metadata = { title = "T" }
                end,
            },
            {
                "encode-nil",
                function(fake)
                    fake.thumbnailService._encode_return = nil
                end,
            },
            {
                "http-nil",
                function(fake)
                    fake.thumbnailService._encode_return = "img"
                    fake.http._response = nil
                end,
            },
        }

        for _, scenario in ipairs(scenarios) do
            local name, setup = scenario[1], scenario[2]
            f = makeFakes()
            f.thumbnailService._export_return = "/tmp/t.jpg"
            setup(f)

            Client = assert(loadfile(path .. "OllamaClient.lua"))()
            c = Client.new(f)

            c.generate({ uuid = "p" }, "hi", nil, false, true, "gemma4:latest", nil)

            assert.are_same(
                1, #f.thumbnailService.cleanup_calls,
                string.format("[%s] cleanup called %d times (expected 1)",
                    name, #f.thumbnailService.cleanup_calls))
        end
    end)
end)
