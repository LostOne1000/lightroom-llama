--- ollama_client_validate_spec.lua — Unit tests for OllamaClient.validateServerHost
--- Tests input normalization, host:port validation, and error cases.

local path = PLUGIN_PATH

describe("OllamaClient.validateServerHost", function()
    local client

    before_each(function()
        client = assert(loadfile(path .. "OllamaClient.lua"))()
    end)

    --------------------------------------------------------------------
    -- Defaults
    --------------------------------------------------------------------
    describe("defaults", function()
        it("accepts nil and returns default host", function()
            local ok, result = client.validateServerHost(nil)
            assert.is_true(ok)
            assert.are_same("localhost:11434", result)
        end)

        it("accepts empty string and returns default host", function()
            local ok, result = client.validateServerHost("")
            assert.is_true(ok)
            assert.are_same("localhost:11434", result)
        end)
    end)

    --------------------------------------------------------------------
    -- Valid inputs
    --------------------------------------------------------------------
    describe("valid inputs", function()
        it("accepts localhost with default port", function()
            local ok, result = client.validateServerHost("localhost:11434")
            assert.is_true(ok)
            assert.are_same("localhost:11434", result)
        end)

        it("accepts IP address with port", function()
            local ok, result = client.validateServerHost("192.168.1.10:11434")
            assert.is_true(ok)
            assert.are_same("192.168.1.10:11434", result)
        end)

        it("accepts domain name with port", function()
            local ok, result = client.validateServerHost("ollama.example.com:9000")
            assert.is_true(ok)
            assert.are_same("ollama.example.com:9000", result)
        end)

        it("strips http:// scheme", function()
            local ok, result = client.validateServerHost("http://localhost:11434")
            assert.is_true(ok)
            assert.are_same("localhost:11434", result)
        end)

        it("strips https:// scheme", function()
            local ok, result = client.validateServerHost("https://myserver:8080")
            assert.is_true(ok)
            assert.are_same("myserver:8080", result)
        end)

        it("strips trailing slashes", function()
            local ok, result = client.validateServerHost("localhost:11434///")
            assert.is_true(ok)
            assert.are_same("localhost:11434", result)
        end)

        it("handles scheme + trailing slash combo", function()
            local ok, result = client.validateServerHost("http://host:8080/")
            assert.is_true(ok)
            assert.are_same("host:8080", result)
        end)

        it("accepts port edge values", function()
            local ok1, _ = client.validateServerHost("h:1")
            assert.is_true(ok1)
            local ok2, _ = client.validateServerHost("h:65535")
            assert.is_true(ok2)
        end)
    end)

    --------------------------------------------------------------------
    -- Invalid inputs
    --------------------------------------------------------------------
    describe("invalid inputs", function()
        it("rejects missing port", function()
            local ok, err = client.validateServerHost("localhost")
            assert.is_false(ok)
            assert.is_not_nil(err)
        end)

        it("rejects non-numeric port", function()
            local ok, err = client.validateServerHost("host:abc")
            assert.is_false(ok)
        end)

        it("rejects port > 65535", function()
            local ok, err = client.validateServerHost("h:99999")
            assert.is_false(ok)
        end)

        it("rejects port 0", function()
            local ok, err = client.validateServerHost("h:0")
            assert.is_false(ok)
        end)

        it("rejects hostname with invalid characters", function()
            local ok, err = client.validateServerHost("host name:80")
            assert.is_false(ok)
        end)

        it("rejects bare scheme without host", function()
            local ok, err = client.validateServerHost("http://")
            assert.is_false(ok)
        end)
    end)
end)
