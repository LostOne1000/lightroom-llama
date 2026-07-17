--- common_delegation_spec.lua — Verify Common.lua exports all expected keys and
--- that each delegated function behaves correctly. Because loadfile() creates new
--- function objects on each call, we test behavior (output equivalence) rather
--- than pointer identity.

local path = PLUGIN_PATH

describe("Common.lua delegation", function()
    local Common

    before_each(function()
        _PLUGIN = { path = path }
        Common = assert(loadfile(path .. "Common.lua"))()
    end)

    --------------------------------------------------------------------
    -- All expected keys are present and non-nil
    --------------------------------------------------------------------
    describe("exports", function()
        it("has all expected constants", function()
            assert.is_not_nil(Common.model)
            assert.is_not_nil(Common.defaultServerHost)
        end)

        it("has all expected functions", function()
            assert.is_function(Common.validateServerHost)
            assert.is_function(Common.makeModelItems)
            assert.is_function(Common.saveServerAndRefresh)
            assert.is_function(Common.fetchAvailableModels)
            assert.is_function(Common.exportThumbnail)
            assert.is_function(Common.base64EncodeImage)
            assert.is_function(Common.sendDataToApi)
            assert.is_function(Common.addKeywordsWithParent)
            assert.is_function(Common.getLlmKeywordsFromPhoto)
            assert.is_function(Common.removeLlmKeywords)
        end)

        it("exports correct default values", function()
            assert.are_same("gemma4:latest", Common.model)
            assert.are_same("localhost:11434", Common.defaultServerHost)
        end)
    end)

    --------------------------------------------------------------------
    -- Delegated functions produce correct results
    --------------------------------------------------------------------
    describe("validateServerHost delegation", function()
        it("accepts localhost:11434", function()
            local ok, result = Common.validateServerHost("localhost:11434")
            assert.is_true(ok)
            assert.are_same("localhost:11434", result)
        end)

        it("rejects missing port", function()
            local ok = Common.validateServerHost("localhost")
            assert.is_false(ok)
        end)

        it("normalizes http:// prefix", function()
            local ok, result = Common.validateServerHost("http://192.168.1.5:9000/")
            assert.is_true(ok)
            assert.are_same("192.168.1.5:9000", result)
        end)
    end)

    describe("makeModelItems delegation", function()
        it("converts model names to title/value pairs", function()
            local items = Common.makeModelItems({ "gemma4:latest", "llama3" })
            assert.are_same(2, #items)
            assert.are_same("gemma4:latest", items[1].title)
            assert.are_same("gemma4:latest", items[1].value)
        end)
    end)

    describe("sendDataToApi wrapper", function()
        it("is a function, not a table or nil", function()
            assert.is_function(Common.sendDataToApi)
        end)
    end)

    describe("fetchAvailableModels wrapper", function()
        it("is a function, not a table or nil", function()
            assert.is_function(Common.fetchAvailableModels)
        end)
    end)
end)
