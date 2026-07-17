--- common_delegation_spec.lua — Behavioral delegation regression tests for
--- Common.lua compatibility layer.
---
--- Every exported function is tested with fake focused modules to prove that
--- the compatibility layer forwards arguments correctly, propagates return
--- values unchanged, and doesn't silently swallow errors. Because loadfile()
--- creates new function objects each call, these tests use behavioral
--- equivalence (spy recording) rather than pointer identity.

local path = PLUGIN_PATH

--------------------------------------------------------------------------------
--- Helper: pack arguments so nil intermediates don't get lost by # operator.
local function pack(...)
    return { n = select("#", ...), ... }
end

--------------------------------------------------------------------------------
-- Suite 1: Production load test — verify default Common loads and has all keys
--------------------------------------------------------------------------------
describe("Common.lua production load", function()
    local Common

    before_each(function()
        _PLUGIN = { path = path }
        Common = assert(loadfile(path .. "Common.lua"))()
    end)

    it("exports correct default constant values", function()
        assert.are_same("gemma4:latest", Common.model)
        assert.are_same("localhost:11434", Common.defaultServerHost)
    end)

    it("has all expected functions", function()
        local expectedFunctions = {
            "validateServerHost",
            "makeModelItems",
            "saveServerAndRefresh",
            "fetchAvailableModels",
            "exportThumbnail",
            "base64EncodeImage",
            "sendDataToApi",
            "addKeywordsWithParent",
            "getLlmKeywordsFromPhoto",
            "removeLlmKeywords",
            "parseKeywordCsv",
        }
        for _, name in ipairs(expectedFunctions) do
            assert.is_function(
                Common[name],
                string.format("Common must export '%s' function", name)
            )
        end
    end)

    it("has constructor for test dependency injection", function()
        assert.is_function(Common.new, "Common must export 'new' constructor")
    end)
end)

--------------------------------------------------------------------------------
-- Suite 2: Behavioral delegation with fake modules
--------------------------------------------------------------------------------
describe("Common.lua delegation behavior", function()

    -- Build a fresh set of fakes + common instance before each test.
    local fakeOllamaClient
    local fakeThumbnailService
    local fakeMetadataService
    local fakePrefsService
    local expectedPrefs
    local common

    before_each(function()
        expectedPrefs = {
            ollamaServerHost = "remote-server:11434",
            _prefsMarker = {}, -- unique identity marker
        }

        fakeOllamaClient = {
            defaultModel = "test-model:42",
            defaultServerHost = "test-host:1234",
            validateServerHost = function() return true, "ok" end,
            makeModelItems = function() return {} end,
            saveServerAndRefresh = function() return true, "refreshed" end,
            fetchModels = function() return {} end,
            generate = function() return {}, nil end,
        }

        fakeThumbnailService = {
            export = function() return "/fake/thumbnail.jpg" end,
            encodeBase64 = function() return "fake-base64-data" end,
        }

        fakeMetadataService = {
            addKeywordsWithParent = function() end,
            getLlmKeywordsFromPhoto = function() return {} end,
            removeLlmKeywords = function() end,
            parseKeywordCsv = function() return {} end,
        }

        fakePrefsService = {
            prefsForPlugin = function() return expectedPrefs end,
        }

        -- Load Common.lua fresh to get the constructor. We only need the `new`
        -- method; the production instance loads fine under mock_sdk but we want
        -- isolated fakes for behavioral tests.
        _PLUGIN = { path = path }
        local CommonModule = assert(loadfile(path .. "Common.lua"))()
        common = CommonModule.new({
            ollamaClient = fakeOllamaClient,
            thumbnailService = fakeThumbnailService,
            metadataService = fakeMetadataService,
            prefsService = fakePrefsService,
        })
    end)

    ------------------------------------------------------------------------
    -- 1. Constants
    ------------------------------------------------------------------------
    describe("constants", function()
        it("exposes model from ollamaClient.defaultModel", function()
            assert.are_same("test-model:42", common.model)
        end)

        it("exposes defaultServerHost from ollamaClient.defaultServerHost", function()
            assert.are_same("test-host:1234", common.defaultServerHost)
        end)
    end)

    ------------------------------------------------------------------------
    -- 2. Direct OllamaClient aliases — validateServerHost
    ------------------------------------------------------------------------
    describe("validateServerHost delegation", function()
        it("forwards all arguments and propagates all return values", function()
            local received
            fakeOllamaClient.validateServerHost = function(...)
                received = pack(...)
                return "ret-1", "ret-2", "ret-3"
            end

            local a, b, c = common.validateServerHost("host:1234", "extra")
            assert.are_same(2, received.n)
            assert.are_same("host:1234", received[1])
            assert.are_same("extra", received[2])
            assert.are_same("ret-1", a)
            assert.are_same("ret-2", b)
            assert.are_same("ret-3", c)
        end)
    end)

    ------------------------------------------------------------------------
    -- 2b. Direct OllamaClient aliases — makeModelItems
    ------------------------------------------------------------------------
    describe("makeModelItems delegation", function()
        it("forwards arguments and propagates return value", function()
            local received
            local expectedItems = {
                { title = "m1", value = "m1" },
                { title = "m2", value = "m2" },
            }
            fakeOllamaClient.makeModelItems = function(models)
                received = models
                return expectedItems
            end

            local models = { "m1", "m2" }
            local result = common.makeModelItems(models)
            assert.is_true(received == models, "same table passed through")
            assert.are_same(expectedItems, result)
        end)
    end)

    ------------------------------------------------------------------------
    -- 2c. Direct OllamaClient aliases — saveServerAndRefresh
    ------------------------------------------------------------------------
    describe("saveServerAndRefresh delegation", function()
        it("forwards all arguments and propagates all return values", function()
            local received
            fakeOllamaClient.saveServerAndRefresh = function(...)
                received = pack(...)
                return true, "models-reloaded"
            end

            local props = { serverHost = "localhost:11434", _marker = "props" }
            local prefs = { ollamaServerHost = "localhost:11434", _marker = "prefs" }

            local a, b = common.saveServerAndRefresh(props, prefs)
            assert.are_same(2, received.n)
            assert.is_true(received[1] == props, "same props object")
            assert.is_true(received[2] == prefs, "same prefs object")
            assert.is_true(a)
            assert.are_same("models-reloaded", b)
        end)
    end)

    ------------------------------------------------------------------------
    -- 3. fetchAvailableModels wrapper
    ------------------------------------------------------------------------
    describe("fetchAvailableModels delegation", function()
        it("calls prefsForPlugin and passes the exact result to fetchModels", function()
            local receivedPrefs
            fakeOllamaClient.fetchModels = function(prefs)
                receivedPrefs = prefs
                return { "model-a", "model-b" }
            end

            local models = common.fetchAvailableModels()
            -- Identity check: same object, not just equal contents
            assert.is_true(
                receivedPrefs == expectedPrefs,
                "fetchAvailableModels must pass the exact prefs object from prefsForPlugin()"
            )
            assert.are_same({ "model-a", "model-b" }, models)
        end)

        it("passes no extra arguments to fetchModels", function()
            local argCount = 0
            fakeOllamaClient.fetchModels = function(...)
                argCount = select("#", ...)
            end

            common.fetchAvailableModels()
            assert.are_same(1, argCount, "fetchModels should receive exactly 1 argument (prefs)")
        end)

        it("propagates all return values from fetchModels", function()
            fakeOllamaClient.fetchModels = function()
                return { "only-one" }, "second-return"
            end

            local a, b = common.fetchAvailableModels()
            assert.are_same({ "only-one" }, a)
            assert.are_same("second-return", b)
        end)

        it("surfaces errors from fetchModels instead of swallowing them", function()
            fakeOllamaClient.fetchModels = function()
                error("fetch-models-failure")
            end

            local ok, err = pcall(common.fetchAvailableModels)
            assert.is_false(ok, "should propagate errors from fetchModels")
            assert.truthy(
                string.find(err, "fetch-models-failure", 1, true),
                string.format("error message should mention the original failure, got: %s", tostring(err))
            )
        end)
    end)

    ------------------------------------------------------------------------
    -- 4. sendDataToApi wrapper — highest priority
    ------------------------------------------------------------------------
    describe("sendDataToApi delegation", function()
        it("forwards all 7 arguments in correct order", function()
            local received
            fakeOllamaClient.generate = function(...)
                received = pack(...)
                return { title = "T", caption = "C", keywords = { "k1" } }, nil
            end

            local photo       = { _type = "photo" }
            local prompt      = "PROMPT-ARGUMENT"
            local currentData = { title = "CURRENT-TITLE", caption = "CURRENT-CAPTION" }
            local useCurrent  = true
            local useSystem   = false
            local model       = "MODEL-ARGUMENT"
            local sysPrompt   = "SYSTEM-PROMPT-ARGUMENT"

            common.sendDataToApi(photo, prompt, currentData, useCurrent,
                                 useSystem, model, sysPrompt)

            assert.are_same(7, received.n, "generate must receive all 7 arguments")
            assert.is_true(received[1] == photo, "arg 1: photo identity")
            assert.are_same(prompt, received[2], "arg 2: prompt value")
            assert.is_true(received[3] == currentData, "arg 3: currentData identity")
            assert.is_true(received[4] == useCurrent, "arg 4: useCurrentData boolean")
            assert.is_false(received[5], "arg 5: useSystemPrompt boolean")
            assert.are_same(model, received[6], "arg 6: selectedModel value")
            assert.are_same(sysPrompt, received[7], "arg 7: systemPrompt value")
        end)

        it("preserves nil middle arguments without shifting later args", function()
            local received
            fakeOllamaClient.generate = function(...)
                received = pack(...)
                return {}, nil
            end

            common.sendDataToApi(
                { _p = "photo" },   -- 1: photo
                "prompt",          -- 2: prompt
                nil,              -- 3: currentData is nil
                true,             -- 4: useCurrentData
                false,            -- 5: useSystemPrompt
                nil,             -- 6: selectedModel is nil
                "sys-prompt"      -- 7: systemPrompt
            )

            assert.are_same(7, received.n, "must forward exactly 7 positions even with nil intermediates")
            assert.is_true(type(received[1]) == "table", "arg 1 should be the photo table")
            assert.are_same("prompt", received[2], "arg 2 should be 'prompt'")
            assert.is_nil(received[3], "arg 3 should be nil (currentData)")
            assert.is_true(received[4], "arg 4 should be true (useCurrentData)")
            assert.is_false(received[5], "arg 5 should be false (useSystemPrompt)")
            assert.is_nil(received[6], "arg 6 should be nil (selectedModel)")
            assert.are_same("sys-prompt", received[7], "arg 7 should still be system prompt")
        end)

        it("propagates both return values on success", function()
            local response = {
                title = "Generated title",
                caption = "Generated caption",
                keywords = { "one", "two" },
            }
            fakeOllamaClient.generate = function()
                return response, nil
            end

            local a, b = common.sendDataToApi(nil, nil, nil, nil, nil, nil, nil)
            assert.is_true(a == response, "response table identity preserved")
            assert.is_nil(b, "error should be nil on success")
        end)

        it("propagates both return values on failure", function()
            fakeOllamaClient.generate = function()
                return nil, "generation failed"
            end

            local a, b = common.sendDataToApi(nil, nil, nil, nil, nil, nil, nil)
            assert.is_nil(a, "response should be nil on failure")
            assert.are_same("generation failed", b)
        end)

        it("surfaces errors from generate instead of swallowing", function()
            fakeOllamaClient.generate = function()
                error("generate-wrapper-failure")
            end

            local ok, err = pcall(common.sendDataToApi, nil, nil, nil, nil, nil, nil, nil)
            assert.is_false(ok, "should propagate errors from generate")
            assert.truthy(
                string.find(err, "generate-wrapper-failure", 1, true),
                string.format("error message should mention the original failure, got: %s", tostring(err))
            )
        end)
    end)

    ------------------------------------------------------------------------
    -- 5. ThumbnailService delegation
    ------------------------------------------------------------------------
    describe("exportThumbnail delegation", function()
        it("forwards photo and propagates return value", function()
            local received
            fakeThumbnailService.export = function(photo)
                received = photo
                return "/fake/thumbnail-123.jpg"
            end

            local photo = { _type = "photo" }
            local result = common.exportThumbnail(photo)
            assert.is_true(received == photo, "same photo object forwarded")
            assert.are_same("/fake/thumbnail-123.jpg", result)
        end)

        it("propagates multiple return values", function()
            local received
            fakeThumbnailService.export = function(p)
                received = p
                return "/path.jpg", "extra-return"
            end

            local a, b = common.exportThumbnail({ _m = 1 })
            assert.is_true(received == { _m = 1 } or received._m == 1)
            assert.are_same("/path.jpg", a)
            assert.are_same("extra-return", b)
        end)
    end)

    describe("base64EncodeImage delegation", function()
        it("forwards path and propagates return value", function()
            local received
            fakeThumbnailService.encodeBase64 = function(imagePath)
                received = imagePath
                return "encoded-data-xyz"
            end

            local result = common.base64EncodeImage("/some/image.jpg")
            assert.are_same("/some/image.jpg", received)
            assert.are_same("encoded-data-xyz", result)
        end)

        it("propagates multiple return values", function()
            local received
            fakeThumbnailService.encodeBase64 = function(path)
                received = path
                return "data", "second"
            end

            local a, b = common.base64EncodeImage("/path.jpg")
            assert.are_same("/path.jpg", received)
            assert.are_same("data", a)
            assert.are_same("second", b)
        end)
    end)

    ------------------------------------------------------------------------
    -- 6. MetadataService delegation
    ------------------------------------------------------------------------
    describe("addKeywordsWithParent delegation", function()
        it("forwards all arguments with correct identity", function()
            local receivedCatalog, receivedPhoto, receivedKw
            fakeMetadataService.addKeywordsWithParent = function(catalog, photo, keywords)
                receivedCatalog = catalog
                receivedPhoto = photo
                receivedKw = keywords
            end

            local catalog  = { _type = "catalog" }
            local photo    = { _type = "photo" }
            local keywords = { "sunset", "portrait" }

            common.addKeywordsWithParent(catalog, photo, keywords)
            assert.is_true(receivedCatalog == catalog, "same catalog object")
            assert.is_true(receivedPhoto == photo, "same photo object")
            assert.is_true(receivedKw == keywords, "same keywords table")
        end)
    end)

    describe("getLlmKeywordsFromPhoto delegation", function()
        it("forwards photo and propagates return value", function()
            local received
            local expectedResult = { "cat", "outdoor" }
            fakeMetadataService.getLlmKeywordsFromPhoto = function(photo)
                received = photo
                return expectedResult
            end

            local photo = { _type = "photo" }
            local result = common.getLlmKeywordsFromPhoto(photo)
            assert.is_true(received == photo, "same photo object")
            assert.are_same(expectedResult, result)
        end)
    end)

    describe("removeLlmKeywords delegation", function()
        it("forwards catalog and photo with correct identity", function()
            local receivedCatalog, receivedPhoto
            fakeMetadataService.removeLlmKeywords = function(catalog, photo)
                receivedCatalog = catalog
                receivedPhoto = photo
            end

            local catalog = { _type = "catalog" }
            local photo   = { _type = "photo" }

            common.removeLlmKeywords(catalog, photo)
            assert.is_true(receivedCatalog == catalog, "same catalog object")
            assert.is_true(receivedPhoto == photo, "same photo object")
        end)
    end)

    describe("parseKeywordCsv delegation", function()
        it("delegates to MetadataService instead of duplicating parser logic", function()
            local receivedCsv
            fakeMetadataService.parseKeywordCsv = function(value)
                receivedCsv = value
                return { "delegated-result" }
            end

            local result = common.parseKeywordCsv("sunset, beach, portrait")
            assert.are_same("sunset, beach, portrait", receivedCsv)
            assert.are_same({ "delegated-result" }, result)
        end)

        it("propagates nil input without error", function()
            local receivedCsv
            fakeMetadataService.parseKeywordCsv = function(value)
                receivedCsv = value
                return {}
            end

            common.parseKeywordCsv(nil)
            assert.is_nil(receivedCsv, "nil should be forwarded to the delegate")
        end)
    end)

    ------------------------------------------------------------------------
    -- 7. API surface regression — all expected keys present
    ------------------------------------------------------------------------
    describe("complete API surface", function()
        it("has every expected compatibility key", function()
            local expectedFunctions = {
                "validateServerHost",
                "makeModelItems",
                "saveServerAndRefresh",
                "fetchAvailableModels",
                "exportThumbnail",
                "base64EncodeImage",
                "sendDataToApi",
                "addKeywordsWithParent",
                "getLlmKeywordsFromPhoto",
                "removeLlmKeywords",
                "parseKeywordCsv",
            }
            for _, name in ipairs(expectedFunctions) do
                assert.is_function(
                    common[name],
                    string.format("common must have function '%s'", name)
                )
            end

            -- Constants
            assert.is_not_nil(common.model, "common must have 'model' constant")
            assert.is_not_nil(common.defaultServerHost, "common must have 'defaultServerHost' constant")
        end)
    end)
end)
