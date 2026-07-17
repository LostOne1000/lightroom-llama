--- ThumbnailService.lua — Export, encode, and clean up photo thumbnails.
--- Handles the full thumbnail lifecycle: request JPEG from Lightroom, write to temp,
--- Base64-encode for API payload, and delete after use.
--- SDK imports: LrFileUtils, LrPathUtils, LrStringUtils, LrLogger

local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrStringUtils = import 'LrStringUtils'
local LrLogger = import 'LrLogger'

local logger = LrLogger('LrLlama')

local thumbnail = {}

--- Export a 512×512 JPEG thumbnail to a unique temp file.
--- **Side effect:** writes a file to the system temp directory.
--- Caller is responsible for deleting the returned file after use via `cleanup()`.
---@param photo LrPhoto Photo object from the catalog
---@return string|nil Absolute path on success, nil on failure
function thumbnail.export(photo)
    local tempPath = LrFileUtils.chooseUniqueFileName(LrPathUtils.getStandardFilePath('temp') .. "/thumbnail.jpg")
    logger:info("Attempting to export thumbnail to: " .. tempPath)

    -- Validate that the temp directory exists and is accessible before proceeding
    -- This prevents silent failures when the temp directory is missing or restricted
    local tempDir = LrPathUtils.getStandardFilePath('temp')
    if not LrFileUtils.exists(tempDir) then
        logger:error("Temp directory does not exist: " .. tempDir)
        return nil
    end

    -- Track whether the thumbnail callback successfully wrote data
    -- This flag is set inside the callback to communicate success back to the caller
    local thumbnailSaved = false

    -- Request a 512x512 JPEG thumbnail asynchronously
    -- photo:requestJpegThumbnail() returns (success, result) and executes the callback
    -- with the JPEG binary data if available
    local success, result = photo:requestJpegThumbnail(512, 512, function(jpegData)
        if jpegData then
            -- Open temp file in binary write mode ("wb") to preserve JPEG data integrity
            local tempFile = io.open(tempPath, "wb")
            if tempFile then
                tempFile:write(jpegData)
                tempFile:close()
                thumbnailSaved = true
                logger:info("Thumbnail saved to " .. tempPath)
                return true
            else
                logger:error("Could not open temp file for writing: " .. tempPath)
                return false
            end
        else
            logger:error("No JPEG data received from photo")
            return false
        end
    end)

    -- Verify both the API call succeeded AND the callback wrote the file
    if success and thumbnailSaved then
        -- Final verification: ensure the file actually exists on disk
        -- This catches edge cases where the write appeared successful but the file is missing
        if LrFileUtils.exists(tempPath) then
            logger:info("Thumbnail export successful: " .. tempPath)
            return tempPath
        else
            logger:error("Thumbnail file was not created: " .. tempPath)
            return nil
        end
    else
        logger:warn("Failed to export thumbnail. Success: " .. tostring(success) .. ", Result: " .. tostring(result))
        return nil
    end
end

--- Read a JPEG file and return its Base64-encoded representation.
---@param imagePath string Absolute path to the JPEG file
---@return string|nil Base64 string on success, nil if file unreadable or empty
function thumbnail.encodeBase64(imagePath)
    logger:info("Attempting to encode image: " .. imagePath)

    -- Check if file exists
    if not LrFileUtils.exists(imagePath) then
        logger:error("Image file does not exist: " .. imagePath)
        return nil
    end

    local file = io.open(imagePath, "rb")
    if not file then
        logger:error("Could not open file for reading: " .. imagePath)
        return nil
    end

    local binaryData = file:read("*all")
    file:close()

    if not binaryData or #binaryData == 0 then
        logger:error("No data read from file: " .. imagePath)
        return nil
    end

    local base64Data = LrStringUtils.encodeBase64(binaryData)
    if not base64Data then
        logger:error("Failed to encode image to base64: " .. imagePath)
        return nil
    end

    logger:info("Successfully encoded image to base64. Size: " .. #binaryData .. " bytes")
    return base64Data
end

--- Clean up a temp thumbnail file (idempotent — no error if already missing).
--- Call after the API request completes, regardless of success or failure.
---@param imagePath string Path to delete
function thumbnail.cleanup(imagePath)
    if imagePath and LrFileUtils.exists(imagePath) then
        LrFileUtils.delete(imagePath)
        logger:info("Cleaned up temp thumbnail: " .. imagePath)
    end
end

return thumbnail
