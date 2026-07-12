local enabled = os.getenv("FRESHRSS_LIVE_TEST") == "1"

if not enabled then
    pending("set FRESHRSS_LIVE_TEST=1 to run live FreshRSS checks")
    return
end

package.path = "./freshrss.koplugin/?.lua;" .. package.path
local ltn12 = require("ltn12")
package.preload["socketutil"] = function()
    return {
        set_timeout = function() end,
        reset_timeout = function() end,
        table_sink = function(buffer) return ltn12.sink.table(buffer) end,
    }
end
local API = dofile("./freshrss.koplugin/api.lua")

describe("live FreshRSS API", function()
    it("authenticates and reads the account streams", function()
        local api = API:new{
            base_url = assert(os.getenv("FRESHRSS_API_URL")),
            username = assert(os.getenv("FRESHRSS_USERNAME")),
            api_password = assert(os.getenv("FRESHRSS_API_PASSWORD")),
        }
        local ok, err = api:login()
        assert.is_true(ok, err)
        assert.is_table(api:listSubscriptions())
        assert.is_table(api:unreadCount())
        assert.is_table(api:stream())
    end)
end)
