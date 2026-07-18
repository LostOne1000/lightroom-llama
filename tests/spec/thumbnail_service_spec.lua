--- thumbnail_service_spec.lua — Direct unit tests for ThumbnailService module.
--- Covers cleanup(), encodeBase64(), and export() with mocked SDK dependencies.

local path = PLUGIN_PATH

--------------------------------------------------------------------------------
--- Helper: load ThumbnailService with configurable fake SDK modules.
--- Overrides import() temporarily so that the module captures our fakes as
--- its local LrFileUtils, LrPathUtils, LrStringUtils, LrLogger references.
--------------------------------------------------------------------------------
local function loadWithFakes(fakeLrFileUtils, fakeLrPathUtils, fakeLrStringUtils)
    local oldImport = _G.import

    -- LrLogger is a constructor: LrLogger('name') → logger instance.
    local loggerFactory = setmetatable({}, {
        __call = function(_, _)
            return {
                info   = function() end,
                warn   = function() end,
                error  = function() end,
                enable = function() end,
            }
        end,
    })

    _G.import = function(className)
        if className == "LrFileUtils" then return fakeLrFileUtils end
        if className == "LrPathUtils" then return fakeLrPathUtils end
        if className == "LrStringUtils" then return fakeLrStringUtils end
        if className == "LrLogger"  then return loggerFactory end
        return oldImport(className)
    end

    local thumbnail = dofile(path .. "ThumbnailService.lua")

    -- Restore immediately so other tests are unaffected.
    _G.import = oldImport
    return thumbnail
end

--------------------------------------------------------------------------------
describe("ThumbnailService — cleanup()", function()

    it("deletes an existing file", function()
        local fakeFs = { delete_calls = {} }
        fakeFs.exists = function(p) return true end
        fakeFs.delete = function(p) table.insert(fakeFs.delete_calls, p) end

        local ts = loadWithFakes(fakeFs, {}, {})
        ts.cleanup("/tmp/thumb.jpg")

        assert.are_same(1, #fakeFs.delete_calls)
        assert.are_same("/tmp/thumb.jpg", fakeFs.delete_calls[1])
    end)

    it("does nothing when the file does not exist", function()
        local fakeFs = { delete_calls = {} }
        fakeFs.exists = function(_) return false end
        fakeFs.delete = function(p) table.insert(fakeFs.delete_calls, p) end

        local ts = loadWithFakes(fakeFs, {}, {})
        ts.cleanup("/tmp/gone.jpg")

        assert.are_same(0, #fakeFs.delete_calls)
    end)

    it("does nothing when given a nil path", function()
        local fakeFs = { delete_calls = {} }
        fakeFs.exists = function(p) return true end
        fakeFs.delete = function(p) table.insert(fakeFs.delete_calls, p) end

        local ts = loadWithFakes(fakeFs, {}, {})
        ts.cleanup(nil)

        assert.are_same(0, #fakeFs.delete_calls)
    end)

    it("passes the exact path to deletion", function()
        local fakeFs = { delete_calls = {} }
        local expectedPath = "/var/folders/xx/unique_name.jpg"
        fakeFs.exists = function(p) return p == expectedPath end
        fakeFs.delete = function(p) table.insert(fakeFs.delete_calls, p) end

        local ts = loadWithFakes(fakeFs, {}, {})
        ts.cleanup(expectedPath)

        assert.are_same(1, #fakeFs.delete_calls)
        assert.are_same(expectedPath, fakeFs.delete_calls[1])
    end)
end)

--------------------------------------------------------------------------------
describe("ThumbnailService — encodeBase64()", function()

    it("returns nil when the file does not exist", function()
        local fakeFs = {}
        fakeFs.exists = function(_) return false end

        local ts = loadWithFakes(fakeFs, {}, {})
        local result = ts.encodeBase64("/tmp/nope.jpg")

        assert.is_nil(result)
    end)

    it("returns nil when io.open fails for a file that exists", function()
        -- Mock exists=true but the path doesn't exist on disk, so io.open fails.
        local fakeFs = {}
        fakeFs.exists = function(_) return true end

        local ts = loadWithFakes(fakeFs, {}, {})
        local result = ts.encodeBase64("/nonexistent/doesnotexist.jpg")

        assert.is_nil(result)
    end)

    it("returns nil for an empty file", function()
        -- Create a real empty temp file.
        local tmpname = path .. "empty_test_tmp_" .. os.time() .. ".jpg"
        local f = io.open(tmpname, "wb")
        if f then f:close() end

        local fakeFs = {}
        fakeFs.exists = function(p) return p == tmpname end

        local fakeStrUtils = {}
        fakeStrUtils.encodeBase64 = function(data) return "encoded" end

        local ts = loadWithFakes(fakeFs, {}, fakeStrUtils)
        local result = ts.encodeBase64(tmpname)

        assert.is_nil(result)
        os.remove(tmpname)
    end)

    it("returns encoded value for a valid file", function()
        -- Create a real temp file with known content.
        local tmpname = path .. "valid_test_tmp_" .. os.time() .. ".jpg"
        local f = io.open(tmpname, "wb")
        if f then f:write("\xFF\xD8\xFF\xE0"); f:close() end

        local fakeFs = {}
        fakeFs.exists = function(p) return p == tmpname end

        local encodedBytes = nil
        local fakeStrUtils = {}
        fakeStrUtils.encodeBase64 = function(data)
            encodedBytes = data
            return "base64encoded"
        end

        local ts = loadWithFakes(fakeFs, {}, fakeStrUtils)
        local result = ts.encodeBase64(tmpname)

        assert.are_same("base64encoded", result)
        assert.are_same("\xFF\xD8\xFF\xE0", encodedBytes)
        os.remove(tmpname)
    end)

    it("returns nil when the Base64 encoder returns nil", function()
        local tmpname = path .. "encoder_fail_tmp_" .. os.time() .. ".jpg"
        local f = io.open(tmpname, "wb")
        if f then f:write("data"); f:close() end

        local fakeFs = {}
        fakeFs.exists = function(p) return p == tmpname end

        local fakeStrUtils = {}
        fakeStrUtils.encodeBase64 = function(_) return nil end

        local ts = loadWithFakes(fakeFs, {}, fakeStrUtils)
        local result = ts.encodeBase64(tmpname)

        assert.is_nil(result)
        os.remove(tmpname)
    end)
end)

--------------------------------------------------------------------------------
describe("ThumbnailService — export()", function()

    it("returns nil when the temp directory does not exist", function()
        local fakePathUtils = {}
        fakePathUtils.getStandardFilePath = function(kind) return "/nonexistent" end

        local fakeFs = {}
        fakeFs.exists = function(_) return false end
        fakeFs.chooseUniqueFileName = function(template) return template end

        local ts = loadWithFakes(fakeFs, fakePathUtils, {})
        local result = ts.export({ uuid = "p1" })

        assert.is_nil(result)
    end)

    it("returns nil when the photo API returns failure", function()
        local fakePathUtils = {}
        fakePathUtils.getStandardFilePath = function(kind) return "/tmp" end

        local fakeFs = {}
        fakeFs.exists = function(_) return true end
        fakeFs.chooseUniqueFileName = function(template) return template end

        local photo = {
            requestJpegThumbnail = function(_, width, height, cb)
                return false, "no thumbnail available"
            end,
        }

        local ts = loadWithFakes(fakeFs, fakePathUtils, {})
        local result = ts.export(photo)

        assert.is_nil(result)
    end)

    it("returns nil when the callback receives no JPEG data", function()
        local fakePathUtils = {}
        fakePathUtils.getStandardFilePath = function(kind) return "/tmp" end

        local fakeFs = {}
        fakeFs.exists = function(_) return true end
        fakeFs.chooseUniqueFileName = function(template) return template end

        local photo = {
            requestJpegThumbnail = function(_, width, height, cb)
                cb(nil)
                return true, "ok"
            end,
        }

        local ts = loadWithFakes(fakeFs, fakePathUtils, {})
        local result = ts.export(photo)

        assert.is_nil(result)
    end)

    it("returns the path on successful export", function()
        local fakePathUtils = {}
        fakePathUtils.getStandardFilePath = function(kind) return "/tmp" end

        local writtenBytes = nil
        local capturedPath = nil
        local originalIoOpen = io.open
        -- Intercept io.open to capture written data.
        io.open = function(filepath, mode)
            capturedPath = filepath
            return {
                write = function(_, data) writtenBytes = data end,
                close = function() end,
            }
        end

        local fakeFs = {}
        -- exists is called twice: once for temp dir check, once for final verification
        fakeFs.exists = function(_) return true end
        fakeFs.chooseUniqueFileName = function(template) return "/tmp/thumb_1.jpg" end

        local photo = {
            requestJpegThumbnail = function(_, width, height, cb)
                assert.are_same(512, width, "Should request 512px width")
                assert.are_same(512, height, "Should request 512px height")
                cb("JPEG_BINARY_DATA")
                return true, "ok"
            end,
        }

        local ts = loadWithFakes(fakeFs, fakePathUtils, {})
        local result = ts.export(photo)

        io.open = originalIoOpen

        assert.are_same("/tmp/thumb_1.jpg", result)
        assert.are_same("JPEG_BINARY_DATA", writtenBytes)
    end)

    it("returns nil when io.open fails inside the callback", function()
        local fakePathUtils = {}
        fakePathUtils.getStandardFilePath = function(kind) return "/tmp" end

        local originalIoOpen = io.open
        io.open = function(_, _) return nil end  -- simulate file-open failure

        local fakeFs = {}
        fakeFs.exists = function(_) return true end
        fakeFs.chooseUniqueFileName = function(template) return "/tmp/thumb_1.jpg" end

        local photo = {
            requestJpegThumbnail = function(_, width, height, cb)
                cb("JPEG_BINARY_DATA")
                return true, "ok"
            end,
        }

        local ts = loadWithFakes(fakeFs, fakePathUtils, {})
        local result = ts.export(photo)

        io.open = originalIoOpen

        assert.is_nil(result)
    end)

    it("requests 512x512 dimensions", function()
        local fakePathUtils = {}
        fakePathUtils.getStandardFilePath = function(kind) return "/tmp" end

        local dims = { w = nil, h = nil }
        local originalIoOpen = io.open
        io.open = function(_, _)
            return {
                write = function(_, _) end,
                close = function() end,
            }
        end

        local fakeFs = {}
        fakeFs.exists = function(_) return true end
        fakeFs.chooseUniqueFileName = function(template) return "/tmp/thumb_1.jpg" end

        local photo = {
            requestJpegThumbnail = function(_, width, height, cb)
                dims.w = width
                dims.h = height
                cb("data")
                return true, "ok"
            end,
        }

        local ts = loadWithFakes(fakeFs, fakePathUtils, {})
        ts.export(photo)

        io.open = originalIoOpen

        assert.are_same(512, dims.w)
        assert.are_same(512, dims.h)
    end)
end)
