package.path = "./freshrss.koplugin/?.lua;./?.lua;" .. package.path
local helpers = dofile("./spec/helpers.lua")
helpers.install_lfs()

package.preload["datastorage"] = function()
    return {
        getDataDir = function()
            return "/tmp/freshrss-test-data"
        end,
    }
end

local Icons = dofile("./freshrss.koplugin/icons.lua")

describe("FreshRSS icons", function()
    it("resolves Lucide asset paths", function()
        local icons = Icons:new("./freshrss.koplugin")
        assert.equals("./freshrss.koplugin/assets/icons/refresh.svg", icons:path("refresh"))
        assert.equals("./freshrss.koplugin/assets/icons/wifi-off.svg", icons:path("wifi_off"))
        assert.equals("freshrss.refresh", icons:name("refresh"))
        assert.equals("freshrss.wifi-off", icons:name("wifi_off"))
    end)

    it("installs icons into the data icons directory", function()
        local icons = Icons:new("./freshrss.koplugin")
        icons:install()
        local file = io.open("/tmp/freshrss-test-data/icons/freshrss.refresh.svg", "r")
        assert.is_truthy(file)
        if file then file:close() end
    end)
end)
