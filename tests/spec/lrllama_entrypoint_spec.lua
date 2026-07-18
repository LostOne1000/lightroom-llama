--- lrllama_entrypoint_spec.lua — Smoke tests for LrLlama.lua entry point.
--- Because the file imports Lightroom SDK modules at top level (LrApplication,
--- LrDialogs, etc.), it cannot be loaded with loadfile() outside Lightroom.
--- These tests verify structure via source inspection and validate the client
--- adapter interface with a fake Common module.

local path = PLUGIN_PATH

describe("LrLlama.lua entrypoint", function()
    local source

    before_each(function()
        source = assert(io.open(path .. "LrLlama.lua", "r")):read("*a")
    end)

    ---------------------------------------------------------------
    -- A. MODULE LOADING
    ---------------------------------------------------------------
    describe("loads dependency modules", function()
        it("loads Common.lua via loadfile", function()
            assert.truthy(
                string.find(source, 'loadfile.*Common%.lua'),
                "Entrypoint must load Common.lua"
            )
        end)

        it("loads PromptBuilder.lua via loadfile", function()
            assert.truthy(
                string.find(source, 'loadfile.*PromptBuilder%.lua'),
                "Entrypoint must load PromptBuilder.lua"
            )
        end)

        it("loads LlamaDialog.lua via loadfile", function()
            assert.truthy(
                string.find(source, 'loadfile.*LlamaDialog%.lua'),
                "Entrypoint must load LlamaDialog.lua"
            )
        end)
    end)

    ---------------------------------------------------------------
    -- B. ASYNC EXECUTION
    ---------------------------------------------------------------
    describe("async execution", function()
        it("runs main in LrTasks.startAsyncTask", function()
            assert.truthy(
                string.find(source, "LrTasks%.startAsyncTask"),
                "Entrypoint must start async task"
            )
        end)
    end)

    ---------------------------------------------------------------
    -- C. NO-PHOTO SAFEGUARD
    ---------------------------------------------------------------
    describe("no-photo safeguard", function()
        it("gets target photos from catalog", function()
            assert.truthy(
                string.find(source, "getTargetPhotos"),
                "Entrypoint must query selected photos"
            )
        end)

        it("checks for empty selection", function()
            assert.truthy(
                string.find(source, "#selectedPhotos == 0"),
                "Entrypoint must guard against no selection"
            )
        end)

        it("shows message when no photo selected", function()
            assert.truthy(
                string.find(source, "LrDialogs%.message"),
                "Entrypoint must show error message for empty selection"
            )
        end)
    end)

    ---------------------------------------------------------------
    -- D. CLIENT ADAPTER INTERFACE
    ---------------------------------------------------------------
    describe("client adapter", function()
        it("defines makeClientAdapter function", function()
            assert.truthy(
                string.find(source, "function makeClientAdapter"),
                "Entrypoint must define makeClientAdapter"
            )
        end)

        it("adapter delegates generate to Common.sendDataToApi", function()
            assert.truthy(
                string.find(source, "common%.sendDataToApi"),
                "Adapter must delegate generate to Common.sendDataToApi"
            )
        end)

        it("adapter delegates fetchModels to Common.fetchAvailableModels", function()
            assert.truthy(
                string.find(source, "common%.fetchAvailableModels"),
                "Adapter must delegate fetchModels"
            )
        end)

        it("adapter exposes validateServerHost", function()
            assert.truthy(
                string.find(source, "validateServerHost.*common%.validateServerHost"),
                "Adapter must expose validateServerHost from Common"
            )
        end)

        it("adapter exposes saveServerAndRefresh", function()
            assert.truthy(
                string.find(source, "saveServerAndRefresh.*common%.saveServerAndRefresh"),
                "Adapter must expose saveServerAndRefresh from Common"
            )
        end)

        it("adapter exposes makeModelItems", function()
            assert.truthy(
                string.find(source, "makeModelItems.*common%.makeModelItems"),
                "Adapter must expose makeModelItems from Common"
            )
        end)

        it("adapter exposes defaultModel constant", function()
            assert.truthy(
                string.find(source, "defaultModel.*=.*common%.model"),
                "Adapter must expose defaultModel from Common.model"
            )
        end)

        it("adapter exposes defaultServerHost constant", function()
            assert.truthy(
                string.find(source, "defaultServerHost.*=.*common%.defaultServerHost"),
                "Adapter must expose defaultServerHost"
            )
        end)
    end)

    ---------------------------------------------------------------
    -- E. DELEGATION TO LLAMADIALOG
    ---------------------------------------------------------------
    describe("delegation to LlamaDialog", function()
        it("calls LlamaDialog.show with client adapter", function()
            assert.truthy(
                string.find(source, "LlamaDialog%.show"),
                "Entrypoint must call LlamaDialog.show"
            )
        end)

        it("passes client to dialog", function()
            assert.truthy(
                string.find(source, "client.*=.*makeClientAdapter"),
                "Entrypoint must pass client adapter to dialog"
            )
        end)

        it("passes common to dialog", function()
            assert.truthy(
                string.find(source, "= Common"),
                "Entrypoint must pass common utilities to dialog"
            )
        end)

        it("passes promptBuilder to dialog", function()
            assert.truthy(
                string.find(source, "= PromptBuilder"),
                "Entrypoint must pass promptBuilder to dialog"
            )
        end)

        it("passes prefs to dialog", function()
            assert.truthy(
                string.find(source, "LrPrefs.prefsForPlugin"),
                "Entrypoint must pass prefs to dialog"
            )
        end)

        it("passes catalog and photo to dialog", function()
            assert.truthy(string.find(source, "catalog[[:%s]]*="))
            assert.truthy(string.find(source, "photo[[:%s]]*="))
        end)

        it("passes thumbnailPath to dialog", function()
            assert.truthy(
                string.find(source, "thumbnailPath"),
                "Entrypoint must pass thumbnail path to dialog"
            )
        end)

        it("passes statusMessages to dialog", function()
            assert.truthy(
                string.find(source, "statusMessages"),
                "Entrypoint must pass status messages to dialog"
            )
        end)

        it("passes writeMetadata callback to dialog", function()
            assert.truthy(
                string.find(source, "writeMetadata"),
                "Entrypoint must pass writeMetadata callback"
            )
        end)
    end)

    ---------------------------------------------------------------
    -- F. WRITEMETADATA CLOSURE
    ---------------------------------------------------------------
    describe("writeMetadata closure", function()
        it("uses catalog withWriteAccessDo for transactional writes", function()
            assert.truthy(
                string.find(source, "withWriteAccessDo"),
                "writeMetadata must use catalog transaction"
            )
        end)

        it("sets title via setRawMetadata", function()
            assert.truthy(
                string.find(source, 'setRawMetadata.*title'),
                "writeMetadata must set title"
            )
        end)

        it("sets caption via setRawMetadata", function()
            assert.truthy(
                string.find(source, 'setRawMetadata.*caption'),
                "writeMetadata must set caption"
            )
        end)

        it("adds keywords via Common.addKeywordsWithParent", function()
            assert.truthy(
                string.find(source, "Common%.addKeywordsWithParent"),
                "writeMetadata must use addKeywordsWithParent for keywords"
            )
        end)
    end)

    ---------------------------------------------------------------
    -- G. NO INLINE BUSINESS LOGIC
    ---------------------------------------------------------------
    describe("no inline business logic", function()
        it("has no inline keyword parsing loop", function()
            assert.falsy(
                string.find(source, "gmatch.*keywords.*%[%,", nil, true),
                "Entrypoint must not contain inline gmatch keyword parsing"
            )
        end)

        it("has no HTTP calls — delegates to Common/adapter", function()
            assert.falsy(
                string.find(source, "LrHttp"),
                "Entrypoint must not make HTTP calls directly"
            )
        end)

        it("has no LrView usage — delegates to LlamaDialog", function()
            assert.falsy(
                string.find(source, "LrView"),
                "Entrypoint must not construct UI directly"
            )
        end)

        it("has no binding construction — delegates to LlamaDialog", function()
            assert.falsy(
                string.find(source, "LrBinding"),
                "Entrypoint must not create bindings directly"
            )
        end)
    end)
end)

describe("makeClientAdapter interface shape", function()
    -- Verify the adapter interface matches what SinglePhotoController expects.
    -- Build a minimal fake Common and inline the adapter logic to ensure the
    -- contract is stable.

    local function makeFakeCommon()
        return {
            sendDataToApi = function() return {}, nil end,
            fetchAvailableModels = function() return {} end,
            validateServerHost = function(host) return true, host end,
            saveServerAndRefresh = function(state, prefs) return true, "ok" end,
            makeModelItems = function(names) return names end,
            model = "gemma4:latest",
            defaultServerHost = "localhost:11434",
        }
    end

    local function makeClientAdapter(common)
        return {
            generate = function(photo, userInstruction, currentData, useCurrentData,
                                useSystemPrompt, selectedModel, systemPromptOverride)
                return common.sendDataToApi(photo, userInstruction, currentData,
                                           useCurrentData, useSystemPrompt,
                                           selectedModel, systemPromptOverride)
            end,
            fetchModels = function()
                return common.fetchAvailableModels()
            end,
            validateServerHost     = common.validateServerHost,
            saveServerAndRefresh   = common.saveServerAndRefresh,
            makeModelItems         = common.makeModelItems,
            defaultModel          = common.model,
            defaultServerHost     = common.defaultServerHost,
        }
    end

    local adapter
    local fakeCommon

    before_each(function()
        fakeCommon = makeFakeCommon()
        adapter = makeClientAdapter(fakeCommon)
    end)

    it("has all required methods", function()
        assert.is_function(adapter.generate)
        assert.is_function(adapter.fetchModels)
        assert.is_function(adapter.validateServerHost)
        assert.is_function(adapter.saveServerAndRefresh)
        assert.is_function(adapter.makeModelItems)
    end)

    it("has all required constants", function()
        assert.are_same("gemma4:latest", adapter.defaultModel)
        assert.are_same("localhost:11434", adapter.defaultServerHost)
    end)

    it("generate delegates to sendDataToApi with correct arg count", function()
        local callArgs = nil
        fakeCommon.sendDataToApi = function(p, u, c, uc, us, m, s)
            callArgs = { p, u, c, uc, us, m, s }
            return {}, nil
        end

        adapter.generate("photo", "prompt", { title = "T" }, true, true, "model", "sys")
        assert.are_same(7, #callArgs)
        assert.are_same("photo", callArgs[1])
        assert.are_same("prompt", callArgs[2])
    end)

    it("fetchModels delegates to fetchAvailableModels", function()
        local called = false
        fakeCommon.fetchAvailableModels = function()
            called = true
            return { "m1" }
        end
        local result = adapter.fetchModels()
        assert.is_true(called)
        assert.are_same({ "m1" }, result)
    end)

    it("validateServerHost is the Common function", function()
        local ok, host = adapter.validateServerHost("host:1234")
        assert.is_true(ok)
        assert.are_same("host:1234", host)
    end)

    it("saveServerAndRefresh passes through correctly", function()
        local ok, msg = adapter.saveServerAndRefresh({}, {})
        assert.is_true(ok)
        assert.are_same("ok", msg)
    end)

    it("matches SinglePhotoController expected interface keys", function()
        -- Mirror the dependency validation in SinglePhotoController.new()
        -- to catch interface drift.
        local expectedKeys = {
            "generate", "fetchModels", "validateServerHost",
            "saveServerAndRefresh", "makeModelItems",
            "defaultModel", "defaultServerHost"
        }
        for _, key in ipairs(expectedKeys) do
            assert.is_not_nil(
                adapter[key],
                string.format("Adapter must have '%s' for SinglePhotoController", key)
            )
        end
    end)
end)
