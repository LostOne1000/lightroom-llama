--- MetadataService.lua — Read and write photo metadata (title, caption, keywords).
--- Manages the `llm` parent keyword hierarchy: creating it, adding children, reading
--- existing keywords, and removing llm-parented keywords from photos.
--- SDK imports: LrLogger only. Catalog and photo objects are passed as parameters.

local LrLogger = import 'LrLogger'

local logger = LrLogger('LrLlama')

local metadata = {}

--- Add keywords under the `llm` parent keyword (idempotent).
--- Creates (or retrieves) a top-level `llm` keyword, then adds each entry as a child
--- and associates it with the photo. Safe to call on photos that already have LLM
--- keywords — duplicate keyword names are handled by Lightroom's createKeyword API.
---@param catalog LrCatalog Active catalog (from LrApplication.activeCatalog())
---@param photo LrPhoto Target photo
---@param keywords table<string> Array of keyword strings to add
function metadata.addKeywordsWithParent(catalog, photo, keywords)
    if not keywords or type(keywords) ~= "table" then
        return
    end

    -- First create or get the parent 'llm' keyword
    local llmKeyword = catalog:createKeyword("llm", nil, true, nil, true)
    if not llmKeyword then
        error("Failed to create or get 'llm' parent keyword")
    end

    for _, keyword in ipairs(keywords) do
        if keyword and keyword ~= "" then
            -- Create child keyword under 'llm' parent
            local childKeyword = catalog:createKeyword(keyword, nil, true, llmKeyword, true)
            if childKeyword then
                photo:addKeyword(childKeyword)
            else
                logger:warn("Failed to create keyword: " .. tostring(keyword))
            end
        end
    end
end

--- Read existing llm-parented keywords from a photo.
--- Filters all keywords to only those whose parent is `llm`. Wrapped in
--- `pcall` so that malformed keyword data doesn't crash the plugin.
---@param photo LrPhoto Target photo
---@return table<string> Keyword name strings (may be empty)
function metadata.getLlmKeywordsFromPhoto(photo)
    local llmKeywords = {}

    -- Wrap in pcall to catch any errors
    local success, result = pcall(function()
        local allKeywords = photo:getRawMetadata("keywords")

        if allKeywords then
            for _, keyword in ipairs(allKeywords) do
                local parent = keyword:getParent()
                if parent and parent:getName() == "llm" then
                    table.insert(llmKeywords, keyword:getName())
                end
            end
        end
    end)

    if not success then
        logger:warn("Error getting LLM keywords: " .. tostring(result))
        return {} -- Return empty array on error
    end

    return llmKeywords
end

--- Remove all llm-parented keywords from a photo.
--- Only removes the keyword-to-photo association — does not delete the keyword
--- definitions from the catalog (other photos may reference them).
---@param catalog LrCatalog Active catalog
---@param photo LrPhoto Target photo
function metadata.removeLlmKeywords(catalog, photo)
    local allKeywords = photo:getRawMetadata("keywords")
    if not allKeywords then
        return
    end

    local keywordsToRemove = {}
    for _, keyword in ipairs(allKeywords) do
        local parent = keyword:getParent()
        if parent and parent:getName() == "llm" then
            table.insert(keywordsToRemove, keyword)
        end
    end

    for _, keyword in ipairs(keywordsToRemove) do
        photo:removeKeyword(keyword)
    end
end

--- Parse a comma-separated keyword string into a trimmed list.
--- Filters out empty entries. Used when reading keywords from the dialog's
--- edit field, where the user enters "sunset, beach, calm".
---@param csv string Comma-separated keywords (e.g., "sunset, beach, calm")
---@return table<string> Trimmed keyword strings, empty entries filtered out
function metadata.parseKeywordCsv(csv)
    if not csv or csv == "" then
        return {}
    end

    local result = {}
    for keyword in string.gmatch(csv, "([^,]+)") do
        local trimmed = keyword:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            table.insert(result, trimmed)
        end
    end
    return result
end

return metadata
