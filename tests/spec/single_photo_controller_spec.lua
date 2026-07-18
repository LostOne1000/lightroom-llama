--- single_photo_controller_spec.lua — Unit tests for SinglePhotoController.
--- Covers initial state, generate success/failure, save server, save metadata.

local path = PLUGIN_PATH

--------------------------------------------------------------------------------
--- Helper: build fresh fake dependencies each test.
--------------------------------------------------------------------------------
local function makeFakes()
    -- Consolidated fake: serves as photo, common, and client simultaneously.
    -- Tests pass the same table for multiple dep roles to keep things simple.
    local f = {}

    -- photo fake with getFormattedMetadata
    f.metadata = { title = "", caption = "" }
    f.getFormattedMetadata = function(_, key)
        return f.metadata[key] or ""
    end

    -- common fake (parseKeywordCsv + getLlmKeywordsFromPhoto)
    f.parseKeywordCsv = function(csv)
        if not csv or csv == "" then return {} end
        local result = {}
        for kw in string.gmatch(csv, "([^,]+)") do
            local trimmed = kw:match("^%s*(.-)%s*$")
            if trimmed ~= "" then table.insert(result, trimmed) end
        end
        return result
    end
    f.getLlmKeywordsFromPhoto = function()
        return f.keywords or {}
    end

    -- client fake constants
    f.defaultModel = "gemma4:latest"
    f.defaultServerHost = "localhost:11434"
    f.fetchModels_called = false
    f.fetchModels_models = { "gemma4:latest", "llama3" }
    f.generate_calls = {}
    f.generate_response = nil
    f.generate_error = nil
    f.makeModelItems = function(names)
        local items = {}
        for _, n in ipairs(names) do
            table.insert(items, { title = n, value = n })
        end
        return items
    end

    -- saveServerAndRefresh tracking
    f.saveServerAndRefresh_calls = {}
    f.saveServerAndRefresh_ok = true
    f.saveServerAndRefresh_msg = "Loaded 2 model(s)"

    f.validateServerHost_called = false
    f.validateServerHost_ok = true
    f.validateServerHost_result = "localhost:11434"

    return f
end

local function buildClient(client)
    client.fetchModels = function()
        client.fetchModels_called = true
        return client.fetchModels_models
    end
    client.generate = function(photo, instruction, currentData, useCurrent,
                               useSystem, model, systemOverride)
        table.insert(client.generate_calls, {
            photo = photo, instruction = instruction,
            currentData = currentData, useCurrent = useCurrent,
            useSystem = useSystem, model = model, systemOverride = systemOverride
        })
        return client.generate_response, client.generate_error
    end
    client.saveServerAndRefresh = function(state, prefs)
        table.insert(client.saveServerAndRefresh_calls, { state, prefs })
        return client.saveServerAndRefresh_ok,
               client.saveServerAndRefresh_msg
    end
    client.validateServerHost = function(input)
        client.validateServerHost_called = true
        return client.validateServerHost_ok,
               client.validateServerHost_result
    end
    return client
end

--------------------------------------------------------------------------------
describe("SinglePhotoController", function()
    local Controller

    before_each(function()
        Controller = assert(loadfile(path .. "SinglePhotoController.lua"))()
    end)

    ---------------------------------------------------------------
    -- A. INITIAL STATE
    ---------------------------------------------------------------
    describe("initial state", function()

        it("empty title/caption → useCurrentData = false", function()
            local f = makeFakes()
            buildClient(f)
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f,
                catalog = {}
            })
            local state = ctrl.initState()
            assert.is_false(state.useCurrentData)
        end)

        it("existing title → useCurrentData = true", function()
            local f = makeFakes()
            buildClient(f)
            f.metadata.title = "Sunset"
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            assert.is_true(state.useCurrentData)
        end)

        it("existing caption → useCurrentData = true", function()
            local f = makeFakes()
            buildClient(f)
            f.metadata.caption = "A beach"
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            assert.is_true(state.useCurrentData)
        end)

        it("joins existing LLM keywords with commas", function()
            local f = makeFakes()
            buildClient(f)
            f.keywords = { "sunset", "beach" }
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            assert.are_same("sunset, beach", state.keywords)
        end)

        it("uses saved server host from prefs", function()
            local f = makeFakes()
            buildClient(f)
            local prefs = { ollamaServerHost = "myhost:9000" }
            local ctrl = Controller.new({
                client = f, common = f, prefs = prefs, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            assert.are_same("myhost:9000", state.serverHost)
        end)

        it("uses default server host when prefs missing", function()
            local f = makeFakes()
            buildClient(f)
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            assert.are_same("localhost:11434", state.serverHost)
        end)

        it("fetches available models", function()
            local f = makeFakes()
            buildClient(f)
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            ctrl.initState()
            assert.is_true(f.fetchModels_called)
        end)

        it("builds model items from fetched models", function()
            local f = makeFakes()
            buildClient(f)
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            assert.are_same(2, #state.modelItems)
            assert.are_same("gemma4:latest", state.modelItems[1].title)
            assert.are_same("llama3",        state.modelItems[2].title)
        end)

        it("selects first model by default", function()
            local f = makeFakes()
            buildClient(f)
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            assert.are_same("gemma4:latest", state.selectedModel)
        end)

        it("sets default prompt and system-prompt settings", function()
            local f = makeFakes()
            buildClient(f)
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            assert.are_same("Caption this photo", state.prompt)
            assert.is_true(state.useSystemPrompt)
        end)

    end)

    ---------------------------------------------------------------
    -- B. GENERATE SUCCESS
    ---------------------------------------------------------------
    describe("generate — success", function()

        it("calls API with all expected arguments", function()
            local f = makeFakes()
            buildClient(f)
            f.generate_response = { title = "T", caption = "C", keywords = { "k" } }
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {},
                promptBuilder = { singlePhotoSystemPrompt = "sys" }
            })
            local state = ctrl.initState()
            ctrl.generate(state)
            assert.are_same(1, #f.generate_calls)
        end)

        it("sets status to working before API call", function()
            local f = makeFakes()
            buildClient(f)
            f.generate_response = { title = "T", caption = "C", keywords = {} }
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()

            -- Override generate to check status at call time
            local capturedStatus = nil
            f.generate = function(...)
                capturedStatus = state.statusKind
                return f.generate_response
            end
            ctrl.generate(state)
            assert.are_same("working", capturedStatus)
        end)

        it("updates title, caption from response", function()
            local f = makeFakes()
            buildClient(f)
            f.generate_response = { title = "New T", caption = "New C", keywords = {} }
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            ctrl.generate(state)
            assert.are_same("New T", state.title)
            assert.are_same("New C", state.caption)
        end)

        it("joins keyword array into comma-separated string", function()
            local f = makeFakes()
            buildClient(f)
            f.generate_response = { title = "T", caption = "C", keywords = { "a", "b" } }
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            ctrl.generate(state)
            assert.are_same("a, b", state.keywords)
        end)

        it("retains response data in state", function()
            local f = makeFakes()
            buildClient(f)
            f.generate_response = { title = "T", caption = "C", keywords = {} }
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            ctrl.generate(state)
            assert.is_not_nil(state.response)
        end)

        it("returns to ready/success status", function()
            local f = makeFakes()
            buildClient(f)
            f.generate_response = { title = "T", caption = "C", keywords = {} }
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            ctrl.generate(state)
            assert.are_same("success", state.statusKind)
        end)

        it("returns a successful result table", function()
            local f = makeFakes()
            buildClient(f)
            f.generate_response = { title = "T", caption = "C", keywords = {} }
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            local result = ctrl.generate(state)
            assert.is_true(result.ok)
        end)

    end)

    ---------------------------------------------------------------
    -- C. GENERATE FAILURE
    ---------------------------------------------------------------
    describe("generate — failure", function()

        it("preserves existing editable fields on error", function()
            local f = makeFakes()
            buildClient(f)
            f.generate_error = "network failure"
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            -- Mutate fields before generate to verify preservation
            state.title = "Existing Title"

            ctrl.generate(state)
            assert.are_same("Existing Title", state.title)
        end)

        it("sets status to error", function()
            local f = makeFakes()
            buildClient(f)
            f.generate_error = "boom"
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            ctrl.generate(state)
            assert.are_same("error", state.statusKind)
            assert.truthy(string.find(state.status, "Error"))
        end)

        it("failure result contains the error", function()
            local f = makeFakes()
            buildClient(f)
            f.generate_error = "no network"
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            local result = ctrl.generate(state)
            assert.is_false(result.ok)
        end)

    end)

    ---------------------------------------------------------------
    -- D. SAVE SERVER SUCCESS
    ---------------------------------------------------------------
    describe("saveServer — success", function()

        it("passes state and prefs to saveServerAndRefresh", function()
            local f = makeFakes()
            buildClient(f)
            local prefs = {}
            local ctrl = Controller.new({
                client = f, common = f, prefs = prefs, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            ctrl.saveServer(state)
            assert.are_same(1, #f.saveServerAndRefresh_calls)
        end)

        it("sets success status and message", function()
            local f = makeFakes()
            buildClient(f)
            f.saveServerAndRefresh_msg = "Loaded 3 model(s)"
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            ctrl.saveServer(state)
            assert.are_same("success", state.statusKind)
            assert.are_same(f.saveServerAndRefresh_msg, state.status)
        end)

    end)

    ---------------------------------------------------------------
    -- E. SAVE SERVER FAILURE
    ---------------------------------------------------------------
    describe("saveServer — failure", function()

        it("sets error status", function()
            local f = makeFakes()
            buildClient(f)
            f.saveServerAndRefresh_ok = false
            f.saveServerAndRefresh_msg = "bad server"
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            ctrl.saveServer(state)
            assert.are_same("error", state.statusKind)
        end)

        it("returns failure result", function()
            local f = makeFakes()
            buildClient(f)
            f.saveServerAndRefresh_ok = false
            f.saveServerAndRefresh_msg = "bad server"
            local ctrl = Controller.new({
                client = f, common = f, prefs = {}, photo = f, catalog = {}
            })
            local state = ctrl.initState()
            local result = ctrl.saveServer(state)
            assert.is_false(result.ok)
        end)

    end)

    ---------------------------------------------------------------
    -- F. SAVE METADATA SUCCESS
    ---------------------------------------------------------------
    describe("saveMetadata — success", function()

        it("validates server host and saves to prefs", function()
            local f = makeFakes()
            buildClient(f)
            f.validateServerHost_ok = true
            f.validateServerHost_result = "localhost:11434"
            local prefs = {}
            local written = nil
            local ctrl = Controller.new({
                client = f, common = f, prefs = prefs, photo = f, catalog = {},
                writeMetadata = function(catalog, photo, meta)
                    written = meta
                end,
            })
            local state = ctrl.initState()
            ctrl.saveMetadata(state)
            assert.are_same("localhost:11434", prefs.ollamaServerHost)
        end)

        it("parses keywords through parseKeywordCsv", function()
            local f = makeFakes()
            buildClient(f)
            f.validateServerHost_ok = true
            f.validateServerHost_result = "localhost:11434"
            local prefs = {}
            local written = nil
            local ctrl = Controller.new({
                client = f, common = f, prefs = prefs, photo = f, catalog = {},
                writeMetadata = function(catalog, photo, meta)
                    written = meta
                end,
            })
            local state = ctrl.initState()
            state.keywords = "sunset,, beach,   ,portrait"
            ctrl.saveMetadata(state)
            assert.are_same({ "sunset", "beach", "portrait" }, written.keywords)
        end)

        it("passes title and caption to write adapter", function()
            local f = makeFakes()
            buildClient(f)
            f.validateServerHost_ok = true
            f.validateServerHost_result = "localhost:11434"
            local prefs = {}
            local written = nil
            local ctrl = Controller.new({
                client = f, common = f, prefs = prefs, photo = f, catalog = {},
                writeMetadata = function(catalog, photo, meta)
                    written = meta
                end,
            })
            local state = ctrl.initState()
            state.title = "T"
            state.caption = "C"
            ctrl.saveMetadata(state)
            assert.are_same("T", written.title)
            assert.are_same("C", written.caption)
        end)

        it("returns success result", function()
            local f = makeFakes()
            buildClient(f)
            f.validateServerHost_ok = true
            f.validateServerHost_result = "localhost:11434"
            local prefs = {}
            local ctrl = Controller.new({
                client = f, common = f, prefs = prefs, photo = f, catalog = {},
                writeMetadata = function() end,
            })
            local state = ctrl.initState()
            local result = ctrl.saveMetadata(state)
            assert.is_true(result.ok)
        end)

    end)

    ---------------------------------------------------------------
    -- G. SAVE METADATA VALIDATION FAILURE
    ---------------------------------------------------------------
    describe("saveMetadata — validation failure", function()

        it("returns structured validation error for invalid server", function()
            local f = makeFakes()
            buildClient(f)
            f.validateServerHost_ok = false
            f.validateServerHost_result = "must be host:port"
            local prefs = {}
            local writeCalled = false
            local ctrl = Controller.new({
                client = f, common = f, prefs = prefs, photo = f, catalog = {},
                writeMetadata = function() writeCalled = true end,
            })
            local state = ctrl.initState()
            state.serverHost = "bad"
            local result = ctrl.saveMetadata(state)

            assert.is_false(result.ok)
            assert.are_same("invalid_server", result.errorKind)
            assert.is_not_nil(result.message)
            assert.is_false(writeCalled)
        end)

    end)

end)
