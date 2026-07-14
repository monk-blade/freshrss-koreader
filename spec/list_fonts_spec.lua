package.path = "./freshrss.koplugin/?.lua;./?.lua;" .. package.path

local settings_store = {}
_G.G_reader_settings = {
    readSetting = function(_, key) return settings_store[key] end,
    saveSetting = function(_, key, value) settings_store[key] = value end,
    delSetting = function(_, key) settings_store[key] = nil end,
    flush = function() end,
}

local ListFonts = dofile("./freshrss.koplugin/list_fonts.lua")

describe("FreshRSS list_fonts helpers", function()
    before_each(function()
        settings_store = {}
        ListFonts._resetSessionForTests()
    end)

    it("normalizes font paths for MuPDF css urls", function()
        assert.equals("/mnt/us/koreader/fonts/Noto.ttf", ListFonts.absoluteFontPath("/mnt/us/koreader/fonts/Noto.ttf"))
        assert.equals("/fonts/Roboto.ttf", ListFonts.absoluteFontPath("\\fonts\\Roboto.ttf"))
    end)

    it("resolves readable font paths with basename fallback", function()
        local latin_path = os.tmpname() .. ".ttf"
        local f = assert(io.open(latin_path, "wb"))
        f:write("x")
        f:close()
        local base = latin_path:match("([^/]+)$")
        local fonts = { latin_path, "/other/Other-Regular.ttf" }
        assert.equals(latin_path, ListFonts.resolveFontPath(base, fonts))
        assert.equals(latin_path, ListFonts.resolveFontPath(latin_path, fonts))
        os.remove(latin_path)
    end)

    it("reads and saves a single viewer font including latin legacy key", function()
        assert.is_nil(ListFonts.readViewerFont())
        ListFonts.saveViewerFont("/fonts/Reader.ttf")
        assert.equals("/fonts/Reader.ttf", ListFonts.readViewerFont())
        ListFonts.saveViewerFont(nil)
        assert.is_nil(ListFonts.readViewerFont())
        settings_store[ListFonts.SETTING_VIEWER_LATIN_LEGACY] = "/fonts/LegacyLatin.ttf"
        assert.equals("/fonts/LegacyLatin.ttf", ListFonts.readViewerFont())
    end)

    it("normalizes font keys for matching", function()
        assert.equals("robotocondensedregular", ListFonts.normalizeFontKey("Roboto-Condensed-Regular.ttf"))
        assert.equals("", ListFonts.normalizeFontKey(nil))
        assert.is_true(ListFonts.normalizeFontKey("RobotoCondensed-Regular.ttf"):find("robotocondensed", 1, true) ~= nil)
    end)

    it("matches font paths against latin hints", function()
        assert.is_true(ListFonts.pathMatchesHints(
            "/usr/fonts/RobotoCondensed-Regular.ttf",
            ListFonts.LATIN_HINTS
        ))
        assert.is_false(ListFonts.pathMatchesHints(
            "NotoSans-Regular.ttf",
            ListFonts.LATIN_HINTS
        ))
    end)

    it("prefers regular faces when auto-detecting", function()
        local fonts = {
            "/fonts/RobotoCondensed-Bold.ttf",
            "/fonts/RobotoCondensed-Regular.ttf",
        }
        assert.equals("/fonts/RobotoCondensed-Regular.ttf", ListFonts.findInstalledFont(ListFonts.LATIN_HINTS, fonts))
    end)

    it("resolves saved latin list font without FontList scan", function()
        assert.is_nil(ListFonts.resolveLatinFont())
        ListFonts.saveLatinFont("/custom/Latin.ttf")
        assert.equals("/custom/Latin.ttf", ListFonts.resolveLatinFont())
        ListFonts.saveLatinFont(nil)
        assert.is_nil(ListFonts.resolveLatinFont())
        local fonts = { "/fonts/RobotoCondensed-Regular.ttf" }
        assert.equals("/fonts/RobotoCondensed-Regular.ttf", ListFonts.resolveLatinFont(fonts))
    end)

    it("clamps and persists list font size", function()
        assert.equals(ListFonts.DEFAULT_SIZE, ListFonts.readFontSize())
        ListFonts.saveFontSize(10)
        assert.equals(ListFonts.SIZE_MIN, ListFonts.readFontSize())
        ListFonts.saveFontSize(40)
        assert.equals(ListFonts.SIZE_MAX, ListFonts.readFontSize())
        ListFonts.saveFontSize(18)
        assert.equals(18, ListFonts.readFontSize())
    end)

    it("displayName shows friendly basename or Default", function()
        assert.equals("Default", ListFonts.displayName(nil))
        assert.equals("Roboto", ListFonts.displayName("/a/b/Roboto.ttf"))
        assert.equals("Rasa", ListFonts.displayName("/fonts/Rasa-VariableFont_wght.ttf"))
    end)

    it("viewerFontLabel reflects saved or default font", function()
        assert.equals("Viewer font: Default", ListFonts.viewerFontLabel())
        ListFonts.saveViewerFont("/fonts/NotoSans.ttf")
        assert.equals("Viewer font: NotoSans", ListFonts.viewerFontLabel())
    end)

    it("builds missing-font hint when preferred latin font absent", function()
        local msg = ListFonts.missingFontsHint({})
        assert.truthy(msg:find("Roboto Condensed", 1, true))
        local fonts = { "/fonts/RobotoCondensed-Regular.ttf" }
        assert.is_nil(ListFonts.missingFontsHint(fonts))
        local shown = {}
        assert.is_true(ListFonts.maybeShowMissingHint(function(m) shown[#shown + 1] = m end, {}))
        assert.equals(1, #shown)
        assert.is_false(ListFonts.maybeShowMissingHint(function() end, {}))
    end)

    it("apply and restore are safe no-ops", function()
        ListFonts.apply()
        ListFonts.restore()
        ListFonts.apply()
        ListFonts.restore()
    end)
end)
