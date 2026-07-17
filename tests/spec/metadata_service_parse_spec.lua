--- metadata_service_parse_spec.lua — Unit tests for MetadataService.parseKeywordCsv
--- Tests CSV parsing, trimming, and edge cases. Does not test catalog-bound
--- methods (addKeywordsWithParent, getLlmKeywordsFromPhoto, removeLlmKeywords)
--- since they require real Lightroom SDK objects.

local path = PLUGIN_PATH

describe("MetadataService.parseKeywordCsv", function()
    local metadata

    before_each(function()
        metadata = assert(loadfile(path .. "MetadataService.lua"))()
    end)

    it("returns empty table for nil input", function()
        assert.are_same({}, metadata.parseKeywordCsv(nil))
    end)

    it("returns empty table for empty string", function()
        assert.are_same({}, metadata.parseKeywordCsv(""))
    end)

    it("parses a single keyword", function()
        assert.are_same({ "sunset" }, metadata.parseKeywordCsv("sunset"))
    end)

    it("parses multiple keywords", function()
        local got = metadata.parseKeywordCsv("beach, sunset, calm")
        assert.are_same({ "beach", "sunset", "calm" }, got)
    end)

    it("trims whitespace around each keyword", function()
        local got = metadata.parseKeywordCsv("  ocean  ,  hills  , sky  ")
        assert.are_same({ "ocean", "hills", "sky" }, got)
    end)

    it("filters out empty entries from consecutive commas", function()
        local got = metadata.parseKeywordCsv("a,,b, ,c")
        assert.are_same({ "a", "b", "c" }, got)
    end)

    it("handles trailing comma", function()
        local got = metadata.parseKeywordCsv("one, two,")
        assert.are_same({ "one", "two" }, got)
    end)

    it("handles leading comma", function()
        local got = metadata.parseKeywordCsv(",first, second")
        assert.are_same({ "first", "second" }, got)
    end)
end)
