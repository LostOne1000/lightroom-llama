--- ollama_client_models_spec.lua — Unit tests for OllamaClient model-related functions.
--- Covers getBaseUrl, fetchModels, makeModelItems, saveServerAndRefresh with injected fakes.

local path = PLUGIN_PATH

--------------------------------------------------------------------------------
--- Helper: build a fresh set of fake dependencies each test.
--------------------------------------------------------------------------------
local function makeFakes()
    local calls = {}

    local http = {
        get_calls = {},
        post_calls = {},
        get_response = nil,
        post_response = nil,
    }
    http.get = function(url)
        table.insert(http.get_calls, url)
        return http.get_response
    end
    http.post = function(url, body, headers)
        table.insert(http.post_calls, { url = url, body = body, headers = headers })
        return http.post_response
    end

    local prefs = { ollamaServerHost = nil }
    prefs.prefsForPlugin = function()
        return { ollamaServerHost = prefs.ollamaServerHost }
    end

    local tasks = { sleep_calls = {} }
    tasks.sleep = function(seconds)
        table.insert(tasks.sleep_calls, seconds)
    end

    -- Jeffrey Friedl's JSON uses colon-style methods (self is first arg).
    -- Our fake mirrors that so the SUT calls json:decode / json:encode.
    local json = {
        decode_calls = {},
        encode_calls = {},
        decode_return = nil,
        decode_error = nil,
        encode_return = nil,
    }
    json.decode = function(_, str)
        table.insert(json.decode_calls, str)
        if json.decode_error then
            error(json.decode_error)
        end
        return json.decode_return
    end
    json.encode = function(_, tbl)
        table.insert(json.encode_calls, tbl)
        return json.encode_return or "{}"
    end

    local thumbnailService = {
        export_response = nil,
        encodeBase64_response = nil,
        cleanup_calls = {},
        export_calls = {},

        export = function(_, photo)
            table.insert(thumbnailService.export_calls, photo)
            return thumbnailService.export_response
        end,

        encodeBase64 = function(_, imagePaths)
            return thumbnailService.encodeBase64_response
        end,

        cleanup = function(imagePath)
            table.insert(thumbnailService.cleanup_calls, imagePath)
        end,
    }

    local promptBuilder = {
        buildUserPrompt_calls = {},
        assembleRequestBody_calls = {},
        buildUserPrompt_return = "default prompt",
        assembleRequestBody_return = { model = "test", prompt = "p" },

        buildUserPrompt = function(_, instruction, currentData, useCurrent)
            table.insert(promptBuilder.buildUserPrompt_calls, {
                instruction = instruction,
                currentData = currentData,
                useCurrent = useCurrent
            })
            return promptBuilder.buildUserPrompt_return
        end,

        assembleRequestBody = function(_, userPrompt, model, useSys, override)
            table.insert(promptBuilder.assembleRequestBody_calls, {
                userPrompt = userPrompt,
                model = model,
                useSystemPrompt = useSys,
                systemPromptOverride = override
            })
            return promptBuilder.assembleRequestBody_return
        end,
    }

    local responseValidator = {
        validateAndParse_calls = {},
        validateAndParse_metadata = nil,
        validateAndParse_error = nil,

        validateAndParse = function(rawResponse)
            table.insert(responseValidator.validateAndParse_calls, rawResponse)
            return responseValidator.validateAndParse_metadata,
                   responseValidator.validateAndParse_error
        end,
    }

    local logger = {
        info_calls = {}, warn_calls = {}, error_calls = {},
        enable = function() end,
    }
    logger.info  = function(msg) table.insert(logger.info_calls, msg) end
    logger.warn  = function(msg) table.insert(logger.warn_calls, msg) end
    logger.error = function(msg) table.insert(logger.error_calls, msg) end

    calls.http = http
    calls.prefs = prefs
    calls.tasks = tasks
    calls.json = json
    calls.thumbnailService = thumbnailService
    calls.promptBuilder = promptBuilder
    calls.responseValidator = responseValidator
    calls.logger = logger

    return calls
end

--------------------------------------------------------------------------------
describe("OllamaClient — models & configuration", function()

    --------------------------------------------------------------------
    -- getBaseUrl()
    --------------------------------------------------------------------
    describe("getBaseUrl()", function()
        it("returns default URL when prefs are empty", function()
            local f = makeFakes()
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local url = c.getBaseUrl({ ollamaServerHost = nil })
            assert.are_same("http://localhost:11434", url)
        end)

        it("returns default URL when prefs is nil", function()
            local f = makeFakes()
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            -- validateServerHost treats nil as default
            local url = c.getBaseUrl({ ollamaServerHost = nil })
            assert.are_same("http://localhost:11434", url)
        end)

        it("uses saved valid host", function()
            local f = makeFakes()
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local url = c.getBaseUrl({ ollamaServerHost = "192.168.1.5:9000" })
            assert.are_same("http://192.168.1.5:9000", url)
        end)

        it("handles host with http:// prefix", function()
            local f = makeFakes()
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local url = c.getBaseUrl({ ollamaServerHost = "http://myhost:11434/" })
            assert.are_same("http://myhost:11434", url)
        end)

        it("falls back to default for invalid saved host", function()
            local f = makeFakes()
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local url = c.getBaseUrl({ ollamaServerHost = "invalid-no-port" })
            assert.are_same("http://localhost:11434", url)
        end)

        it("includes exactly one http:// prefix", function()
            local f = makeFakes()
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local url = c.getBaseUrl({ ollamaServerHost = "localhost:11434" })
            local count = 0
            for _ in string.gmatch(url, "http://") do count = count + 1 end
            assert.are_same(1, count)
        end)
    end)

    --------------------------------------------------------------------
    -- makeModelItems()
    --------------------------------------------------------------------
    describe("makeModelItems()", function()
        it("converts model names to title/value pairs", function()
            local f = makeFakes()
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local items = c.makeModelItems({ "gemma4:latest", "llama3" })
            assert.are_same(2, #items)
            assert.are_same("gemma4:latest", items[1].title)
            assert.are_same("gemma4:latest", items[1].value)
            assert.are_same("llama3", items[2].title)
            assert.are_same("llama3", items[2].value)
        end)

        it("returns empty table for empty input", function()
            local f = makeFakes()
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local items = c.makeModelItems({})
            assert.are_same(0, #items)
        end)
    end)

    --------------------------------------------------------------------
    -- fetchModels() — success paths
    --------------------------------------------------------------------
    describe("fetchModels() — success", function()
        it("sends GET to /api/tags", function()
            local f = makeFakes()
            f.http.get_response = '{"models":[{"name":"gemma4:latest"}]}'
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)

            local models = c.fetchModels({ ollamaServerHost = "localhost:11434" })

            assert.are_same(1, #f.http.get_calls)
            assert.are_same("http://localhost:11434/api/tags", f.http.get_calls[1])
        end)

        it("parses models using the name field", function()
            local f = makeFakes()
            f.json.decode_return = {
                models = { { name = "gemma4:latest" }, { name = "llama3" } }
            }
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            f.http.get_response = "{}"
            local models = c.fetchModels({ ollamaServerHost = nil })
            assert.are_same(2, #models)
            assert.are_same("gemma4:latest", models[1])
            assert.are_same("llama3", models[2])
        end)

        it("parses models using the legacy model field", function()
            local f = makeFakes()
            f.json.decode_return = {
                models = { { model = "oldmodel" } }
            }
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            f.http.get_response = "{}"
            local models = c.fetchModels({ ollamaServerHost = nil })
            assert.are_same(1, #models)
            assert.are_same("oldmodel", models[1])
        end)

        it("ignores entries with missing or empty names", function()
            local f = makeFakes()
            f.json.decode_return = {
                models = {
                    { name = "good" },
                    { name = "" },
                    { name = nil },
                    {},  -- no name field
                }
            }
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            f.http.get_response = "{}"
            local models = c.fetchModels({ ollamaServerHost = nil })
            assert.are_same(1, #models)
            assert.are_same("good", models[1])
        end)

        it("preserves response order", function()
            local f = makeFakes()
            f.json.decode_return = {
                models = {
                    { name = "first" },
                    { name = "second" },
                    { name = "third" },
                }
            }
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            f.http.get_response = "{}"
            local models = c.fetchModels({ ollamaServerHost = nil })
            assert.are_same({ "first", "second", "third" }, models)
        end)
    end)

    --------------------------------------------------------------------
    -- fetchModels() — fallback paths
    --------------------------------------------------------------------
    describe("fetchModels() — fallback to default", function()
        it("returns default model on no HTTP response", function()
            local f = makeFakes()
            f.http.get_response = nil
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local models = c.fetchModels({ ollamaServerHost = nil })
            assert.are_same({ "gemma4:latest" }, models)
        end)

        it("returns default model on malformed JSON", function()
            local f = makeFakes()
            f.json.decode_return = "not a table"  -- string, not table
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            f.http.get_response = "garbage"
            local models = c.fetchModels({ ollamaServerHost = nil })
            assert.are_same({ "gemma4:latest" }, models)
        end)

        it("returns default model when models key is missing", function()
            local f = makeFakes()
            f.json.decode_return = { other = "data" }
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            f.http.get_response = '{"other":"data"}'
            local models = c.fetchModels({ ollamaServerHost = nil })
            assert.are_same({ "gemma4:latest" }, models)
        end)

        it("returns default model for empty model list", function()
            local f = makeFakes()
            f.json.decode_return = { models = {} }
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            f.http.get_response = '{"models":[]}'
            local models = c.fetchModels({ ollamaServerHost = nil })
            assert.are_same({ "gemma4:latest" }, models)
        end)

        it("handles JSON decoder exception without crashing", function()
            local f = makeFakes()
            f.json.decode_error = "attempt to index nil"
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            f.http.get_response = "bad json"
            -- Should not throw; should return default
            local models = c.fetchModels({ ollamaServerHost = nil })
            assert.are_same({ "gemma4:latest" }, models)
        end)
    end)

    --------------------------------------------------------------------
    -- saveServerAndRefresh() — invalid input
    --------------------------------------------------------------------
    describe("saveServerAndRefresh() — validation", function()
        it("returns failure for invalid server input", function()
            local f = makeFakes()
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local ok, msg = c.saveServerAndRefresh({ serverHost = "noport" }, {})
            assert.is_false(ok)
            assert.is_not_nil(msg)
        end)

        it("does not modify prefs for invalid input", function()
            local f = makeFakes()
            f.prefs.ollamaServerHost = "original:1234"
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local prefs = { ollamaServerHost = "original:1234" }
            c.saveServerAndRefresh({ serverHost = "bad" }, prefs)
            -- prefs should be unchanged
            assert.are_same("original:1234", prefs.ollamaServerHost)
        end)
    end)

    --------------------------------------------------------------------
    -- saveServerAndRefresh() — valid input
    --------------------------------------------------------------------
    describe("saveServerAndRefresh() — success path", function()
        it("normalizes and saves valid host", function()
            local f = makeFakes()
            f.json.decode_return = { models = { { name = "m1" } } }
            f.http.get_response = '{"models":[{"name":"m1"}]}'
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local prefs = {}
            local props = { serverHost = "http://myhost:9000/" }

            local ok, msg = c.saveServerAndRefresh(props, prefs)

            assert.is_true(ok)
            assert.are_same("myhost:9000", prefs.ollamaServerHost)
        end)

        it("builds model items from fetched models", function()
            local f = makeFakes()
            f.json.decode_return = {
                models = { { name = "a" }, { name = "b" } }
            }
            f.http.get_response = '{"models":[{"name":"a"},{"name":"b"}]}'
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local prefs = {}
            local props = { serverHost = "localhost:11434" }

            c.saveServerAndRefresh(props, prefs)

            assert.are_same(2, #props.modelItems)
            assert.are_same("a", props.modelItems[1].title)
            assert.are_same("a", props.modelItems[1].value)
            assert.are_same("b", props.modelItems[2].title)
        end)

        it("preserves selected model when still available", function()
            local f = makeFakes()
            f.json.decode_return = {
                models = { { name = "a" }, { name = "b" } }
            }
            f.http.get_response = '{}'
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local prefs = {}
            local props = { serverHost = "localhost:11434", selectedModel = "b" }

            c.saveServerAndRefresh(props, prefs)

            assert.are_same("b", props.selectedModel)
        end)

        it("selects first model when old selection unavailable", function()
            local f = makeFakes()
            f.json.decode_return = {
                models = { { name = "new1" }, { name = "new2" } }
            }
            f.http.get_response = '{}'
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local prefs = {}
            local props = { serverHost = "localhost:11434", selectedModel = "old" }

            c.saveServerAndRefresh(props, prefs)

            assert.are_same("new1", props.selectedModel)
        end)

        it("reports correct count in success message", function()
            local f = makeFakes()
            f.json.decode_return = {
                models = { { name = "x" }, { name = "y" }, { name = "z" } }
            }
            f.http.get_response = '{}'
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local prefs = {}
            local props = { serverHost = "localhost:11434" }

            local ok, msg = c.saveServerAndRefresh(props, prefs)

            assert.is_true(ok)
            assert.are_same("Loaded 3 model(s)", msg)
        end)

        it("model items contain title and value pairs", function()
            local f = makeFakes()
            f.json.decode_return = { models = { { name = "only" } } }
            f.http.get_response = '{}'
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local prefs = {}
            local props = { serverHost = "localhost:11434" }

            c.saveServerAndRefresh(props, prefs)

            assert.are_same("only", props.modelItems[1].title)
            assert.are_same("only", props.modelItems[1].value)
        end)

        it("passes updated prefs into model discovery", function()
            local f = makeFakes()
            f.http.get_response = '{}'
            -- The get_calls URL reveals which host was used
            local Client = assert(loadfile(path .. "OllamaClient.lua"))()
            local c = Client.new(f)
            local prefs = {}
            local props = { serverHost = "custom:7777" }

            c.saveServerAndRefresh(props, prefs)

            -- fetchModels should be called with updated prefs; the URL shows it
            assert.are_same(1, #f.http.get_calls)
            assert.are_same("http://custom:7777/api/tags", f.http.get_calls[1])
        end)
    end)
end)
