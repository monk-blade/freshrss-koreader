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
        assert.same({ "item-1" }, captured.fields.i)
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

    it("batches edit-tag with multiple item ids", function()
        local api = API:new{ base_url = "https://reader.example/api/greader.php", username = "u", api_password = "p", auth = "u/abc", token = "tok" }
        local captured
        function api:requestRaw(path, method, fields)
            captured = { path = path, method = method, fields = fields }
            return "OK", 200
        end
        local ok = api:editTagMany({ "a", "b", "c" }, "read", true)
        assert.is_true(ok)
        assert.same({ "a", "b", "c" }, captured.fields.i)
        assert.equals("user/-/state/com.google/read", captured.fields.a)
        local encoded = api:encodeFields(captured.fields)
        assert.truthy(encoded:find("i=a", 1, true))
        assert.truthy(encoded:find("i=b", 1, true))
        assert.truthy(encoded:find("i=c", 1, true))
    end)

    it("normalizes decimal itemRefs ids to tag form", function()
        assert.equals(
            "tag:google.com,2005:reader/item/0000000000000064",
            API.normalizeItemId(100)
        )
        assert.equals(
            "tag:google.com,2005:reader/item/abc",
            API.normalizeItemId("tag:google.com,2005:reader/item/abc")
        )
    end)

    it("builds stream paths with unread exclude and continuation", function()
        local api = API:new{ base_url = "https://reader.example/api/greader.php", username = "u", api_password = "p" }
        local path = api:buildStreamPath(nil, { n = 50, exclude_read = true, continuation = "999" })
        assert.truthy(path:find("stream/contents/user/%-/state/com%.google/reading%-list", 1, false))
        assert.truthy(path:find("n=50", 1, true))
        assert.truthy(path:find("r=n", 1, true))
        assert.truthy(path:find("xt=", 1, true))
        assert.truthy(path:find("c=999", 1, true))
    end)

    it("builds stream item ids paths", function()
        local api = API:new{ base_url = "https://reader.example/api/greader.php", username = "u", api_password = "p" }
        local path = api:buildStreamIdsPath(nil, { n = 50, exclude_read = true, continuation = "999" })
        assert.truthy(path:find("stream/items/ids", 1, true))
        assert.truthy(path:find("n=50", 1, true))
        assert.truthy(path:find("s=", 1, true))
        assert.truthy(path:find("xt=", 1, true))
        assert.truthy(path:find("c=999", 1, true))
    end)

    it("parses streamItemIds and posts streamItemContents", function()
        local api = API:new{ base_url = "https://reader.example/api/greader.php", username = "u", api_password = "p", auth = "u/abc", token = "tok" }
        function api:request(path, method, fields)
            if path:find("stream/items/ids", 1, true) then
                return {
                    itemRefs = { { id = "100" }, { id = "101" } },
                    continuation = "next",
                }
            end
            if path:find("stream/items/contents", 1, true) then
                assert.equals("POST", method)
                assert.same({
                    API.normalizeItemId(100),
                    API.normalizeItemId(101),
                }, fields.i)
                return { items = { { id = API.normalizeItemId(100) }, { id = API.normalizeItemId(101) } } }
            end
            return nil, "unexpected"
        end
        local ids_page = api:streamItemIds(nil, { n = 10 })
        assert.equals(2, #ids_page.ids)
        assert.equals("next", ids_page.continuation)
        local contents = api:streamItemContents(ids_page.ids)
        assert.equals(2, #contents.items)
    end)

    it("posts mark-all-as-read with stream and timestamp", function()
        local api = API:new{ base_url = "https://reader.example/api/greader.php", username = "u", api_password = "p", auth = "u/abc", token = "tok" }
        local captured
        function api:requestRaw(path, method, fields)
            captured = { path = path, method = method, fields = fields }
            return "OK", 200
        end
        local ok, err = api:markAllAsRead("user/-/state/com.google/reading-list", 1700000000)
        assert.is_true(ok, err)
        assert.equals("reader/api/0/mark-all-as-read", captured.path)
        assert.equals("POST", captured.method)
        assert.equals("user/-/state/com.google/reading-list", captured.fields.s)
        assert.equals("1700000000", captured.fields.ts)
        assert.equals("tok", captured.fields.T)
    end)
end)
