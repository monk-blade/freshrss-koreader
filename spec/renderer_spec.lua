package.path = "./freshrss.koplugin/?.lua;./?.lua;" .. package.path

-- Renderer sanitize helpers are pure Lua; stub KOReader UI modules so dofile works.
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 0 } end
package.preload["ui/widget/buttontable"] = function() return {} end
package.preload["ui/widget/menu"] = function()
    return {
        new = function(_, opts) return opts or {} end,
    }
end
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 800 end,
            getHeight = function() return 600 end,
            scaleBySize = function(_, n) return n end,
        },
        hasKeys = function() return false end,
        isTouchDevice = function() return false end,
        input = { group = { Back = "Back" } },
    }
end
package.preload["ui/widget/buttondialog"] = function() return {} end
package.preload["ui/widget/spinwidget"] = function() return {} end
package.preload["ui/widget/container/widgetcontainer"] = function()
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
        new = function(_, opts) return opts or {} end,
    }
end
package.preload["ui/gesturerange"] = function() return { new = function() return {} end } end
package.preload["ui/widget/container/framecontainer"] = function() return {} end
-- G_reader_settings stub for viewer setting helpers
local settings_store = {}
_G.G_reader_settings = {
    readSetting = function(_, key) return settings_store[key] end,
    saveSetting = function(_, key, value) settings_store[key] = value end,
    delSetting = function(_, key) settings_store[key] = nil end,
    flush = function() end,
}
package.preload["ui/geometry"] = function() return { new = function(_, t) return t end } end
package.preload["ui/widget/container/inputcontainer"] = function()
    return {
        extend = function(_, t)
            return setmetatable(t, {
                __call = function(cls, opts)
                    local o = setmetatable(opts or {}, { __index = cls })
                    return o
                end,
                __index = {
                    new = function(cls, opts)
                        local o = setmetatable(opts or {}, { __index = cls })
                        return o
                    end,
                },
            })
        end,
    }
end
package.preload["ui/widget/container/movablecontainer"] = function() return {} end
package.preload["ui/widget/scrollhtmlwidget"] = function() return {} end
package.preload["ui/size"] = function() return { padding = { large = 10 } } end
package.preload["ui/widget/titlebar"] = function() return {} end
package.preload["ui/uimanager"] = function() return { close = function() end, show = function() end, setDirty = function() end } end
package.preload["ui/widget/verticalgroup"] = function() return {} end
package.preload["ui/widget/verticalspan"] = function() return {} end
package.preload["fontlist"] = function()
    return { getFontList = function() return { "/fonts/NotoSans.ttf" } end }
end
package.preload["util"] = function()
    return {
        htmlToPlainTextIfHtml = function(s) return s:gsub("<.->", "") end,
        htmlEscape = function(s) return s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;") end,
        htmlEntitiesToUtf8 = function(s) return s end,
    }
end
package.preload["datastorage"] = function()
    return { getDataDir = function() return "/tmp" end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        mkdir = function() return true end,
        attributes = function() return nil end,
    }
end

local Renderer = dofile("./freshrss.koplugin/renderer.lua")

describe("FreshRSS renderer HTML sanitize", function()
    it("strips scripts, iframes, and remote images", function()
        local html = [[<p>Hi</p><script>alert(1)</script><img src="http://x/y.png"><iframe src="x"></iframe>]]
        local out = Renderer.sanitizeHtml(html)
        assert.falsy(out:find("<script", 1, true))
        assert.falsy(out:find("<img", 1, true))
        assert.falsy(out:find("<iframe", 1, true))
        assert.truthy(out:find("%[image%]"))
        assert.truthy(out:find("Hi", 1, true))
    end)

    it("keeps local img src after rewrite", function()
        local html = [[<p>Hi</p><img src="abc123.png"/>]]
        local out = Renderer.sanitizeHtml(html)
        assert.truthy(out:find('src="abc123.png"', 1, true))
        assert.falsy(out:find("%[image%]"))
    end)

    it("strips javascript hrefs and on* handlers", function()
        local html = [[<a href="javascript:alert(1)" onclick="evil()">x</a>]]
        local out = Renderer.sanitizeHtml(html)
        assert.falsy(out:find("javascript:", 1, true))
        assert.falsy(out:find("onclick", 1, true))
    end)

    it("truncates oversized bodies", function()
        local huge = string.rep("a", Renderer.HTML_MAX_BYTES + 100)
        local out = Renderer.sanitizeHtml(huge)
        assert.is_true(#out < #huge + 80)
        assert.truthy(out:find("truncated", 1, true))
    end)

    it("builds a fallback body when html is empty", function()
        local body = Renderer.buildHtmlBody({ html = "" })
        assert.truthy(body:find("No article content", 1, true))
    end)

    it("rewrites remote images when show_images and map provided", function()
        local article = { html = [[<p>x</p><img src="https://cdn/a.png">]] }
        local body = Renderer.buildHtmlBody(article, {
            show_images = true,
            image_map = { ["https://cdn/a.png"] = "deadbeef.png" },
            html_resource_directory = "/tmp/freshrss/images",
        })
        assert.truthy(body:find('src="deadbeef.png"', 1, true))
        assert.falsy(body:find("https://cdn/a.png", 1, true))
    end)
end)

describe("FreshRSS renderer CSS / view settings", function()
    before_each(function()
        for k in pairs(settings_store) do
            settings_store[k] = nil
        end
    end)

    it("injects @font-face when a font path is set", function()
        local css = Renderer.buildCss({
            font_face = "/fonts/NotoSans.ttf",
            line_height = 1.45,
            show_images = false,
        })
        assert.truthy(css:find("@font%-face"))
        assert.truthy(css:find("FreshRSSFont", 1, true))
        assert.truthy(css:find("/fonts/NotoSans.ttf", 1, true))
        assert.truthy(css:find("line%-height: 1%.45"))
    end)

    it("cycles line height values", function()
        local a = Renderer.cycleLineHeight(1.2)
        assert.are.equal(1.45, a)
        local b = Renderer.cycleLineHeight(1.45)
        assert.are.equal(1.7, b)
        local c = Renderer.cycleLineHeight(1.7)
        assert.are.equal(1.2, c)
    end)

    it("defaults show images to on", function()
        assert.is_true(Renderer.readShowImages())
    end)

    it("shows img CSS when images enabled", function()
        local css = Renderer.buildCss({ show_images = true, line_height = 1.2 })
        assert.truthy(css:find("max%-width"))
        assert.falsy(css:find("img { display: none;", 1, true))
    end)
end)
