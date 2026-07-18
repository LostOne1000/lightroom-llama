--- metadata_service_keywords_spec.lua — Unit tests for MetadataService catalog-bound
--- keyword functions: addKeywordsWithParent, getLlmKeywordsFromPhoto, removeLlmKeywords.
--- Uses plain-Lua fake objects; no real Lightroom SDK required.

local path = PLUGIN_PATH

--------------------------------------------------------------------------------
--- Factory helpers for fake Lightroom keyword objects.
--------------------------------------------------------------------------------
local function makeParent(name)
    return {
        getName = function()
            return name
        end,
    }
end

local function makeKeyword(name, parent)
    return {
        getName = function()
            return name
        end,
        getParent = function()
            return parent
        end,
    }
end

--------------------------------------------------------------------------------
--- Helper: build a fake catalog + photo with call recording.
--- Each call returns configurable values set by individual tests.
--------------------------------------------------------------------------------
local function makeFakeCatalog()
    local catalog = {
        createKeyword_calls = {},
        -- Per-call return values: index into this array by call number
        createKeyword_returns = {},
    }
    -- MetadataService calls with colon notation: catalog:createKeyword(...)
    -- so self is passed as first argument. Use dot-notation signature that
    -- explicitly receives and ignores self.
    catalog.createKeyword = function(_, name, _, scope, parent, system)
        table.insert(catalog.createKeyword_calls, {
            name = name,
            scope = scope,
            parent = parent,
            system = system,
        })
        local idx = #catalog.createKeyword_calls
        return catalog.createKeyword_returns[idx]
    end
    return catalog
end

local function makeFakePhoto()
    local photo = {
        addKeyword_calls = {},
        removeKeyword_calls = {},
        getRawMetadata_return = nil,
        getRawMetadata_error = nil,
    }
    -- All called with colon notation: photo:xxx(...) → self is first arg
    photo.addKeyword = function(_, keyword)
        table.insert(photo.addKeyword_calls, keyword)
    end
    photo.removeKeyword = function(_, keyword)
        table.insert(photo.removeKeyword_calls, keyword)
    end
    photo.getRawMetadata = function(_, key)
        if photo.getRawMetadata_error then
            error(photo.getRawMetadata_error)
        end
        return photo.getRawMetadata_return
    end
    return photo
end

--------------------------------------------------------------------------------

describe("MetadataService.addKeywordsWithParent", function()
    local metadata
    local catalog
    local photo

    before_each(function()
        metadata = assert(loadfile(path .. "MetadataService.lua"))()
        catalog = makeFakeCatalog()
        photo = makeFakePhoto()
    end)

    ---------------------------------------------------------------
    --- Invalid input — early return without side effects
    ---------------------------------------------------------------
    describe("invalid input", function()
        it("returns without calling catalog methods for nil", function()
            metadata.addKeywordsWithParent(catalog, photo, nil)
            assert.are_same(0, #catalog.createKeyword_calls)
            assert.are_same(0, #photo.addKeyword_calls)
        end)

        it("returns without calling catalog methods for a string", function()
            metadata.addKeywordsWithParent(catalog, photo, "sunset")
            assert.are_same(0, #catalog.createKeyword_calls)
        end)

        it("returns without calling catalog methods for a number", function()
            metadata.addKeywordsWithParent(catalog, photo, 42)
            assert.are_same(0, #catalog.createKeyword_calls)
        end)

        it("returns without calling catalog methods for a boolean", function()
            metadata.addKeywordsWithParent(catalog, photo, true)
            assert.are_same(0, #catalog.createKeyword_calls)
        end)
    end)

    ---------------------------------------------------------------
    --- Empty table — documents current behavior (parent still created)
    ---------------------------------------------------------------
    describe("empty table", function()
        before_each(function()
            catalog.createKeyword_returns[1] = makeParent("llm")
        end)

        it("creates the llm parent keyword", function()
            metadata.addKeywordsWithParent(catalog, photo, {})
            assert.are_same(1, #catalog.createKeyword_calls)
            assert.are_same("llm", catalog.createKeyword_calls[1].name)
        end)

        it("does not create child keywords", function()
            metadata.addKeywordsWithParent(catalog, photo, {})
            assert.are_same(1, #catalog.createKeyword_calls)
            assert.are_same(0, #photo.addKeyword_calls)
        end)
    end)

    ---------------------------------------------------------------
    --- Parent creation arguments
    ---------------------------------------------------------------
    describe("parent creation", function()
        before_each(function()
            catalog.createKeyword_returns[1] = makeParent("llm")
        end)

        it("creates parent with correct arguments", function()
            metadata.addKeywordsWithParent(catalog, photo, { "sunset" })
            local call = catalog.createKeyword_calls[1]
            assert.are_same("llm", call.name)
            assert.are_same(true, call.scope)
            assert.are_same(nil, call.parent)
            assert.are_same(true, call.system)
        end)
    end)

    ---------------------------------------------------------------
    --- Success path — child creation and association
    ---------------------------------------------------------------
    describe("success path", function()
        local llmParent
        local sunsetChild
        local portraitChild

        before_each(function()
            llmParent = { marker = "llm-parent" }
            sunsetChild = { marker = "sunset-child" }
            portraitChild = { marker = "portrait-child" }
            catalog.createKeyword_returns[1] = llmParent
            catalog.createKeyword_returns[2] = sunsetChild
            catalog.createKeyword_returns[3] = portraitChild
        end)

        it("creates parent once and children under it", function()
            metadata.addKeywordsWithParent(catalog, photo, { "sunset", "portrait" })
            assert.are_same(3, #catalog.createKeyword_calls)
            -- Parent created with nil parent-arg
            assert.are_same(nil, catalog.createKeyword_calls[1].parent)
            -- Children created under exact llmParent object
            assert.is_true(catalog.createKeyword_calls[2].parent == llmParent)
            assert.is_true(catalog.createKeyword_calls[3].parent == llmParent)
        end)

        it("adds each child keyword to the photo in order", function()
            metadata.addKeywordsWithParent(catalog, photo, { "sunset", "portrait" })
            assert.are_same(2, #photo.addKeyword_calls)
            assert.is_true(photo.addKeyword_calls[1] == sunsetChild)
            assert.is_true(photo.addKeyword_calls[2] == portraitChild)
        end)

        it("passes correct arguments for child creation", function()
            metadata.addKeywordsWithParent(catalog, photo, { "sunset" })
            local childCall = catalog.createKeyword_calls[2]
            assert.are_same("sunset", childCall.name)
            assert.are_same(true, childCall.scope)
            assert.is_true(childCall.parent == llmParent)
            assert.are_same(true, childCall.system)
        end)
    end)

    ---------------------------------------------------------------
    --- Empty and nil entries
    ---------------------------------------------------------------
    describe("empty and nil entries", function()
        before_each(function()
            catalog.createKeyword_returns[1] = makeParent("llm")
        end)

        it("skips empty string entries", function()
            local child1 = { marker = "child1" }
            local child2 = { marker = "child2" }
            catalog.createKeyword_returns[2] = child1
            catalog.createKeyword_returns[3] = child2
            metadata.addKeywordsWithParent(catalog, photo, { "sunset", "", "portrait" })
            -- 1 parent + 2 children (empty skipped)
            assert.are_same(3, #catalog.createKeyword_calls)
            assert.are_same(2, #photo.addKeyword_calls)
        end)

        it("stops at nil hole due to ipairs semantics", function()
            local child1 = { marker = "child1" }
            catalog.createKeyword_returns[2] = child1
            -- ipairs stops at first nil, so "portrait" after nil is never reached
            metadata.addKeywordsWithParent(catalog, photo, { "sunset", nil, "portrait" })
            -- 1 parent + 1 child (only "sunset" processed)
            assert.are_same(2, #catalog.createKeyword_calls)
            assert.are_same(1, #photo.addKeyword_calls)
        end)
    end)

    ---------------------------------------------------------------
    --- Partial child creation failure
    ---------------------------------------------------------------
    describe("partial child failure", function()
        before_each(function()
            catalog.createKeyword_returns[1] = makeParent("llm")
            -- First child creation fails (returns nil)
            catalog.createKeyword_returns[2] = nil
            -- Second child succeeds
            catalog.createKeyword_returns[3] = { marker = "portrait-child" }
        end)

        it("skips failed child but continues processing", function()
            metadata.addKeywordsWithParent(catalog, photo, { "sunset", "portrait" })
            -- 1 parent + 2 children attempted
            assert.are_same(3, #catalog.createKeyword_calls)
            -- Only successful child added to photo
            assert.are_same(1, #photo.addKeyword_calls)
        end)

        it("does not call addKeyword for nil child", function()
            metadata.addKeywordsWithParent(catalog, photo, { "sunset", "portrait" })
            -- The first addKeyword would be for sunset (which returned nil) — must not be called
            assert.are_same(1, #photo.addKeyword_calls)
        end)
    end)

    ---------------------------------------------------------------
    --- Parent creation failure
    ---------------------------------------------------------------
    describe("parent creation failure", function()
        before_each(function()
            catalog.createKeyword_returns[1] = nil
        end)

        it("raises error when parent cannot be created", function()
            assert.has_error(
                function()
                    metadata.addKeywordsWithParent(catalog, photo, { "sunset" })
                end,
                "Failed to create or get 'llm' parent keyword"
            )
        end)

        it("does not create children when parent fails", function()
            pcall(function()
                metadata.addKeywordsWithParent(catalog, photo, { "sunset" })
            end)
            -- Only the parent creation was attempted
            assert.are_same(1, #catalog.createKeyword_calls)
            assert.are_same(0, #photo.addKeyword_calls)
        end)
    end)
end)

--------------------------------------------------------------------------------

describe("MetadataService.getLlmKeywordsFromPhoto", function()
    local metadata
    local photo

    before_each(function()
        metadata = assert(loadfile(path .. "MetadataService.lua"))()
        photo = makeFakePhoto()
    end)

    ---------------------------------------------------------------
    --- Keyword filtering
    ---------------------------------------------------------------
    describe("keyword filtering", function()
        it("returns only llm-parented keywords in order", function()
            local llmParent = makeParent("llm")
            local peopleParent = makeParent("people")
            photo.getRawMetadata_return = {
                makeKeyword("dog", peopleParent),    -- not llm
                makeKeyword("sunset", llmParent),   -- llm
                makeKeyword("landscape"),           -- no parent (top-level)
                makeKeyword("portrait", llmParent), -- llm
            }
            local result = metadata.getLlmKeywordsFromPhoto(photo)
            assert.are_same({ "sunset", "portrait" }, result)
        end)

        it("returns empty table when no keywords", function()
            photo.getRawMetadata_return = nil
            assert.are_same({}, metadata.getLlmKeywordsFromPhoto(photo))
        end)

        it("returns empty table for empty keyword list", function()
            photo.getRawMetadata_return = {}
            assert.are_same({}, metadata.getLlmKeywordsFromPhoto(photo))
        end)

        it("requires exact parent name match — rejects LLM", function()
            local llmParent = makeParent("llm")
            local upperParent = makeParent("LLM")
            photo.getRawMetadata_return = {
                makeKeyword("good", llmParent),
                makeKeyword("bad", upperParent),
            }
            assert.are_same({ "good" }, metadata.getLlmKeywordsFromPhoto(photo))
        end)

        it("requires exact parent name match — rejects llm-child and my-llm", function()
            local llmParent = makeParent("llm")
            local childParent = makeParent("llm-child")
            local myParent = makeParent("my-llm")
            photo.getRawMetadata_return = {
                makeKeyword("keep", llmParent),
                makeKeyword("drop1", childParent),
                makeKeyword("drop2", myParent),
            }
            assert.are_same({ "keep" }, metadata.getLlmKeywordsFromPhoto(photo))
        end)
    end)

    ---------------------------------------------------------------
    --- pcall error protection — all-or-nothing behavior
    ---------------------------------------------------------------
    describe("pcall error protection", function()
        it("returns empty table when getRawMetadata raises", function()
            photo.getRawMetadata_error = "metadata unavailable"
            assert.are_same({}, metadata.getLlmKeywordsFromPhoto(photo))
        end)

        it("returns empty table when getParent raises on any keyword", function()
            local llmParent = makeParent("llm")
            local badKeyword = {
                getName = function() return "broken" end,
                getParent = function() error("getParent failed") end,
            }
            photo.getRawMetadata_return = {
                makeKeyword("sunset", llmParent),
                badKeyword,
            }
            -- pcall wraps entire loop — returns {} on any error
            assert.are_same(
                {},
                metadata.getLlmKeywordsFromPhoto(photo),
                "pcall catches getParent error and returns empty table"
            )
        end)

        it("returns empty table when parent getName raises", function()
            local badParent = {
                getName = function() error("getName failed") end,
            }
            photo.getRawMetadata_return = {
                makeKeyword("sunset", badParent),
            }
            assert.are_same(
                {},
                metadata.getLlmKeywordsFromPhoto(photo),
                "pcall catches parent:getName error"
            )
        end)

        it("returns empty table when keyword getName raises after parent match", function()
            -- This tests the case where parent matches "llm" but the keyword's
            -- own getName fails. The pcall wraps the entire loop, so partial
            -- results are discarded — all-or-nothing behavior.
            local goodParent = makeParent("llm")
            local badKeyword = {
                getParent = function() return goodParent end,
                getName = function() error("getName failed") end,
            }
            photo.getRawMetadata_return = {
                makeKeyword("sunset", goodParent),
                badKeyword,
            }
            assert.are_same(
                {},
                metadata.getLlmKeywordsFromPhoto(photo),
                "pcall discards partial results when keyword getName fails"
            )
        end)
    end)
end)

--------------------------------------------------------------------------------

describe("MetadataService.removeLlmKeywords", function()
    local metadata
    local catalog
    local photo

    before_each(function()
        metadata = assert(loadfile(path .. "MetadataService.lua"))()
        catalog = makeFakeCatalog()
        photo = makeFakePhoto()
    end)

    ---------------------------------------------------------------
    --- Removal filtering
    ---------------------------------------------------------------
    describe("removal filtering", function()
        it("removes only llm-parented keywords", function()
            local llmParent = makeParent("llm")
            local peopleParent = makeParent("people")
            local sunsetKeyword  = makeKeyword("sunset", llmParent)
            local dogKeyword     = makeKeyword("dog", peopleParent)
            local landscapeKw    = makeKeyword("landscape")           -- top-level
            local portraitKw    = makeKeyword("portrait", llmParent)

            photo.getRawMetadata_return = {
                sunsetKeyword,  -- index 1 — remove
                dogKeyword,     -- index 2 — keep
                landscapeKw,    -- index 3 — keep (top-level)
                portraitKw,    -- index 4 — remove
            }

            metadata.removeLlmKeywords(catalog, photo)

            assert.are_same(2, #photo.removeKeyword_calls)
            assert.is_true(photo.removeKeyword_calls[1] == sunsetKeyword)
            assert.is_true(photo.removeKeyword_calls[2] == portraitKw)
        end)

        it("does not remove keywords with similar parent names", function()
            local llmParent   = makeParent("llm")
            local upperParent = makeParent("LLM")
            local childParent = makeParent("llm-child")
            local myParent    = makeParent("my-llm")

            photo.getRawMetadata_return = {
                makeKeyword("keep1", llmParent),    -- remove (exact match)
                makeKeyword("keep2", upperParent),  -- keep
                makeKeyword("keep3", childParent),  -- keep
                makeKeyword("keep4", myParent),     -- keep
            }

            metadata.removeLlmKeywords(catalog, photo)

            assert.are_same(1, #photo.removeKeyword_calls)
        end)

        it("returns early when no keyword metadata", function()
            photo.getRawMetadata_return = nil
            metadata.removeLlmKeywords(catalog, photo)
            assert.are_same(0, #photo.removeKeyword_calls)
        end)

        it("does nothing for empty keyword list", function()
            photo.getRawMetadata_return = {}
            metadata.removeLlmKeywords(catalog, photo)
            assert.are_same(0, #photo.removeKeyword_calls)
        end)
    end)

    ---------------------------------------------------------------
    --- Catalog argument behavior
    ---------------------------------------------------------------
    describe("catalog argument", function()
        it("accepts catalog without calling any catalog methods", function()
            local llmParent = makeParent("llm")
            photo.getRawMetadata_return = {
                makeKeyword("sunset", llmParent),
            }
            metadata.removeLlmKeywords(catalog, photo)
            -- removeLlmKeywords accepts catalog but does not use it
            assert.are_same(0, #catalog.createKeyword_calls)
        end)

        it("does not delete keyword definitions from catalog", function()
            -- Use a catalog that throws on any method call to verify nothing is called
            local throwCatalog = {
                createKeyword_calls = {},
                createKeyword = function()
                    error("catalog method should not be called")
                end,
                deleteKeyword = function()
                    error("deleteKeyword should not be called")
                end,
            }
            local llmParent = makeParent("llm")
            photo.getRawMetadata_return = {
                makeKeyword("sunset", llmParent),
            }
            -- Must not raise — function only touches photo, not catalog
            metadata.removeLlmKeywords(throwCatalog, photo)
            assert.are_same(1, #photo.removeKeyword_calls)
        end)
    end)
end)

--------------------------------------------------------------------------------

describe("Error semantics characterization", function()
    --- Documents the asymmetry: getLlmKeywordsFromPhoto uses pcall (returns {} on
    --- error), while removeLlmKeywords does not (propagates errors). This is
    --- intentional behavior — do not change it without an explicit decision.

    local metadata

    before_each(function()
        metadata = assert(loadfile(path .. "MetadataService.lua"))()
    end)

    it("getLlmKeywordsFromPhoto returns {} on metadata error (pcall)", function()
        local photo = makeFakePhoto()
        photo.getRawMetadata_error = "I/O error reading metadata"
        local result = metadata.getLlmKeywordsFromPhoto(photo)
        assert.are_same({}, result)
    end)

    it("removeLlmKeywords propagates metadata error (no pcall)", function()
        local photo = makeFakePhoto()
        photo.getRawMetadata_error = "I/O error reading metadata"
        local catalog = makeFakeCatalog()
        assert.has_error(
            function()
                metadata.removeLlmKeywords(catalog, photo)
            end,
            "I/O error reading metadata"
        )
    end)
end)
