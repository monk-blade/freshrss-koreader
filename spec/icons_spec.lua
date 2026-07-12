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
        assert.equals("./freshrss.koplugin/assets/icons/freshrss.svg", icons:path("freshrss"))
        assert.equals("./freshrss.koplugin/assets/icons/refresh.svg", icons:path("refresh"))
        assert.equals("./freshrss.koplugin/assets/icons/wifi-off.svg", icons:path("wifi_off"))
        assert.equals("./freshrss.koplugin/assets/icons/chevron-left.svg", icons:path("chevron_left"))
        assert.equals("./freshrss.koplugin/assets/icons/list-filter.svg", icons:path("list_filter"))
        assert.equals("./freshrss.koplugin/assets/icons/star-filled.svg", icons:path("star_filled"))
        assert.equals("freshrss.freshrss", icons:name("freshrss"))
        assert.equals("freshrss.refresh", icons:name("refresh"))
        assert.equals("freshrss.wifi-off", icons:name("wifi_off"))
        assert.equals("freshrss.chevron-left", icons:name("chevron_left"))
        assert.equals("freshrss.star-filled", icons:name("star_filled"))
    end)

    it("builds icon-only ButtonTable entries", function()
        local icons = Icons:new("./freshrss.koplugin")
        local called = false
        local entry = icons:button("settings", {
            callback = function() called = true end,
        })
        assert.equals("freshrss.settings", entry.icon)
        assert.is_truthy(entry.icon_width)
        assert.is_truthy(entry.icon_height)
        assert.is_nil(entry.enabled)
        entry.callback()
        assert.is_true(called)

        local disabled = icons:button("chevron_left", {
            enabled = false,
            callback = function() end,
        })
        assert.equals(false, disabled.enabled)
    end)

    it("installs icons into the data icons directory", function()
        local icons = Icons:new("./freshrss.koplugin")
        icons:install()
        local brand = io.open("/tmp/freshrss-test-data/icons/freshrss.freshrss.svg", "r")
        assert.is_truthy(brand)
        if brand then brand:close() end
        local file = io.open("/tmp/freshrss-test-data/icons/freshrss.refresh.svg", "r")
        assert.is_truthy(file)
        if file then file:close() end
        local chevron = io.open("/tmp/freshrss-test-data/icons/freshrss.chevron-left.svg", "r")
        assert.is_truthy(chevron)
        if chevron then chevron:close() end
    end)
end)
