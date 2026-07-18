--- info_spec.lua — Regression tests for the plugin manifest (Info.lua).
--- Validates required fields, repository URLs, version structure, and menu entries.

local path = PLUGIN_PATH

describe("Info.lua manifest", function()
    local info

    before_each(function()
        -- Info.lua returns a plain table; no SDK imports needed.
        info = assert(loadfile(path .. "Info.lua"))()
    end)

    --------------------------------------------------------------------
    -- Plugin identity
    --------------------------------------------------------------------
    describe("identity fields", function()
        it("has the correct plugin name", function()
            assert.are_same("Lightroom Llama", info.LrPluginName)
        end)

        it("has a nonempty description that is not the default placeholder", function()
            assert.is_not_nil(info.LrPluginDescription)
            assert.is_true(#info.LrPluginDescription > 0)
            assert.is_not_same(
                "Description of your Lightroom plugin",
                info.LrPluginDescription
            )
        end)

        it("preserves the original toolkit identifier", function()
            assert.are_same(
                "com.thejoltjoker.lightroom.llama",
                info.LrToolkitIdentifier
            )
        end)
    end)

    --------------------------------------------------------------------
    -- Version structure
    --------------------------------------------------------------------
    describe("VERSION fields are numeric", function()
        it("major", function()
            assert.is_true(type(info.VERSION.major) == "number")
        end)

        it("minor", function()
            assert.is_true(type(info.VERSION.minor) == "number")
        end)

        it("revision", function()
            assert.is_true(type(info.VERSION.revision) == "number")
        end)
    end)

    --------------------------------------------------------------------
    -- URLs point to the forked repository
    --------------------------------------------------------------------
    describe("repository URLs", function()
        it("LrPluginInfoUrl points to active repository", function()
            assert.are_same(
                "https://github.com/LostOne1000/lightroom-llama",
                info.LrPluginInfoUrl
            )
        end)

        it("provider URL uses HTTPS if present", function()
            if info.LrPluginInfoUrlProvider then
                assert.is_true(
                    string.find(info.LrPluginInfoUrlProvider, "^https://") ~= nil,
                    "Provider URL should use HTTPS"
                )
            end
        end)

        it("does not reference the obsolete provider domain", function()
            if info.LrPluginInfoUrlProvider then
                assert.is_not_same(
                    "http://www.thejoltjoker.com",
                    info.LrPluginInfoUrlProvider,
                    "Provider URL should not reference old domain"
                )
            end
        end)
    end)

    --------------------------------------------------------------------
    -- Menu entries
    --------------------------------------------------------------------
    describe("menu configuration", function()
        it("has Library menu items", function()
            assert.is_true(#info.LrLibraryMenuItems >= 1)
        end)

        it("has Export menu items", function()
            assert.is_true(#info.LrExportMenuItems >= 1)
        end)

        it("includes the three expected menu entries in library", function()
            local titles = {}
            for _, item in ipairs(info.LrLibraryMenuItems) do
                table.insert(titles, item.title)
            end
            -- Lua 5.1 has no table.indexOf; use inline check.
            local foundSingle = false
            local foundBatch  = false
            local foundReset  = false
            for _, t in ipairs(titles) do
                if t == "Lightroom Llama..."     then foundSingle = true end
                if t == "Batch Process with Llama..." then foundBatch  = true end
                if t == "Reset Metadata..."      then foundReset  = true end
            end
            assert.is_true(foundSingle, "missing 'Lightroom Llama...' menu item")
            assert.is_true(foundBatch,  "missing 'Batch Process with Llama...' menu item")
            assert.is_true(foundReset,  "missing 'Reset Metadata...' menu item")
        end)
    end)

    --------------------------------------------------------------------
    -- Required manifest fields present
    --------------------------------------------------------------------
    describe("required fields", function()
        local required = {
            "LrPluginName", "LrPluginDescription", "LrToolkitIdentifier",
            "LrSdkVersion", "LrSdkMinimumVersion",
            "LrLibraryMenuItems", "LrExportMenuItems"
        }

        for _, field in ipairs(required) do
            it(field, function()
                assert.is_not_nil(info[field], field .. " should be present")
            end)
        end

        it("SDK version fields are numeric", function()
            assert.is_true(type(info.LrSdkVersion) == "number")
            assert.is_true(type(info.LrSdkMinimumVersion) == "number")
        end)
    end)
end)
