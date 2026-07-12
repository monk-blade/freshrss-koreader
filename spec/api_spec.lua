package.path = "./freshrss.koplugin/?.lua;./?.lua;" .. package.path
local helpers = dofile("./spec/helpers.lua")
helpers.install_json()
package.preload["socketutil"] = function() return { set_timeout = function() end, reset_timeout = function() end, table_sink = function() return function() end end } end
package.preload["socket.http"] = function() return {} end
package.preload["socket.url"] = function() return { escape = function(value) return value end } end
package.preload["ltn12"] = function() return {} end
local API = dofile("./freshrss.koplugin/api.lua")

describe("FreshRSS API", function()
    it("normalizes a FreshRSS instance URL", function()
        local api = API:new{ base_url = "https://reader.example/", username = "u", api_password = "p" }
        assert.equals("https://reader.example/api/greader.php", api.base_url)
    end)

    it("parses the documented plain-text ClientLogin response", function()
        local api = API:new{ base_url = "https://reader.example/api/greader.php", username = "u", api_password = "p" }
        function api:requestRaw(path)
            if path == "accounts/ClientLogin" then return "SID=u/abc\nLSID=u/abc\nAuth=u/abc\n", 200 end
            return "token-value\n", 200
        end
        local ok, err = api:login()
        assert.is_true(ok, err)
        assert.equals("u/abc", api.auth)
        assert.equals("token-value", api.token)
    end)

    it("fails login when the write token is missing", function()
        local api = API:new{ base_url = "https://reader.example/api/greader.php", username = "u", api_password = "p" }
        function api:requestRaw(path)
            if path == "accounts/ClientLogin" then return "Auth=u/abc\n", 200 end
            return nil, 500
        end
        local ok, err = api:login()
        assert.is_false(ok)
        assert.truthy(err)
        assert.is_nil(api.auth)
        assert.is_nil(api.token)
    end)

    it("posts edit-tag to the FreshRSS GReader endpoint", function()
        local api = API:new{ base_url = "https://reader.example/api/greader.php", username = "u", api_password = "p", auth = "u/abc", token = "tok" }
        local captured
        function api:requestRaw(path, method, fields)
            captured = { path = path, method = method, fields = fields }
            return "OK", 200
        end
        local ok, err = api:editTag("item-1", "read", true)
        assert.is_true(ok, err)
        assert.equals("reader/api/0/edit-tag", captured.path)
        assert.equals("POST", captured.method)
        assert.equals("item-1", captured.fields.i)
        assert.equals("user/-/state/com.google/read", captured.fields.a)
        assert.equals("tok", captured.fields.T)
        assert.is_nil(captured.fields.r)
    end)

    it("removes tags with the r field when state is false", function()
        local api = API:new{ base_url = "https://reader.example/api/greader.php", username = "u", api_password = "p", auth = "u/abc", token = "tok" }
        local captured
        function api:requestRaw(path, method, fields)
            captured = { path = path, method = method, fields = fields }
            return "OK", 200
        end
        local ok = api:editTag("item-2", "starred", false)
        assert.is_true(ok)
        assert.equals("user/-/state/com.google/starred", captured.fields.r)
        assert.is_nil(captured.fields.a)
    end)
end)
