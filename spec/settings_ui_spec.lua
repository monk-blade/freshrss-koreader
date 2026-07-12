package.path = "./freshrss.koplugin/?.lua;./?.lua;" .. package.path

package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 0, COLOR_DARK_GRAY = 1 } end
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 800 end,
            getHeight = function() return 600 end,
            scaleBySize = function(_, n) return n end,
        },
        hasKeys = function() return false end,
        input = { group = { Back = "Back" } },
    }
end
package.preload["ui/font"] = function()
    return { getFace = function() return {} end }
end
package.preload["ui/geometry"] = function() return { new = function(_, t) return t end } end
package.preload["ui/gesturerange"] = function() return { new = function() return {} end } end
package.preload["ui/size"] = function()
    return {
        padding = { large = 10, tiny = 1, small = 2 },
        margin = { tiny = 1 },
        border = { thin = 1, thick = 2 },
        span = { horizontal_default = 8 },
        line = { thin = 1 },
        radius = { default = 4 },
    }
end
package.preload["ui/widget/container/centercontainer"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/container/framecontainer"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/container/inputcontainer"] = function()
    return {
        extend = function(_, t)
            return setmetatable(t or {}, {
                __index = {
                    new = function(cls, opts)
                        return setmetatable(opts or {}, { __index = cls })
                    end,
                },
            })
        end,
    }
end
package.preload["ui/widget/horizontalgroup"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/horizontalspan"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/iconwidget"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/iconbutton"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/linewidget"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/textwidget"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/titlebar"] = function() return { new = function(_, o) return o end } end
package.preload["ui/uimanager"] = function()
    return { close = function() end, show = function() end, setDirty = function() end }
end
package.preload["ui/widget/verticalgroup"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/verticalspan"] = function() return { new = function(_, o) return o end } end

local SettingsUI = dofile("./freshrss.koplugin/settings_ui.lua")

describe("FreshRSS settings_ui pagination", function()
    it("slices rows into fixed-size pages", function()
        local rows = { "a", "b", "c", "d", "e" }
        local slice, page, page_count = SettingsUI.sliceRows(rows, 1, 2)
        assert.equals(1, page)
        assert.equals(3, page_count)
        assert.same({ "a", "b" }, slice)

        slice, page, page_count = SettingsUI.sliceRows(rows, 2, 2)
        assert.equals(2, page)
        assert.same({ "c", "d" }, slice)

        slice, page, page_count = SettingsUI.sliceRows(rows, 3, 2)
        assert.equals(3, page)
        assert.same({ "e" }, slice)
    end)

    it("clamps invalid page numbers", function()
        local rows = { 1, 2, 3 }
        local slice, page, page_count = SettingsUI.sliceRows(rows, 99, 2)
        assert.equals(2, page)
        assert.equals(2, page_count)
        assert.same({ 3 }, slice)
    end)

    it("handles empty row lists", function()
        local slice, page, page_count = SettingsUI.sliceRows({}, 1, SettingsUI.ICON_PAGE_SIZE)
        assert.equals(1, page)
        assert.equals(1, page_count)
        assert.same({}, slice)
    end)
end)
