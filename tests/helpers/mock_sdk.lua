--- mock_sdk.lua — Minimal Lightroom SDK stubs for unit testing modules
--- that import LrPathUtils, LrLogger, LrPrefs, etc. at load time.
---
--- Runs automatically before each spec via busted.json "helpers" config.

-- Resolve the .lrplugin root relative to this helper file's location so tests
-- work on any developer's machine regardless of where the repo is cloned.
-- The structure is:  <repo>/tests/helpers/  (this file)
--                     <repo>/lightroom-llama.lrplugin/  (target)
local helperDir = string.match(debug.getinfo(1, "S").source, "^@(.*/)") or ""
PLUGIN_PATH = helperDir .. "../..//lightroom-llama.lrplugin/"

-- _PLUGIN is a global Lightroom injects. Point it at the real plugin dir so
-- loadfile() can find JSON.lua and sibling modules.
_G._PLUGIN = { path = PLUGIN_PATH }

-- import() is the Lightroom SDK class loader. Return a stub for each class
--- that a module might request.
import = function(className)
    if className == "LrPathUtils" then
        return {
            child = function(parent, name)
                return parent .. "/" .. name
            end,
        }
    end

    if className == "LrLogger" then
        -- LrLogger is called as a constructor: LrLogger('name') → logger instance
        return setmetatable({}, {
            __call = function(_, _)
                return {
                    info  = function() end,
                    warn  = function() end,
                    error = function() end,
                    enable = function() end,
                }
            end,
        })
    end

    if className == "LrPrefs" then
        return { prefsForPlugin = function() return {} end }
    end

    if className == "LrHttp" then
        return {}
    end

    if className == "LrTasks" then
        return { sleep = function(_) end }
    end

    -- Unknown classes get a blank table so loadfile() keeps working.
    return {}
end
