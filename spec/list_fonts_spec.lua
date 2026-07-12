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

    it("detects Gujarati Unicode in titles", function()
        assert.is_false(ListFonts.containsGujarati(nil))
        assert.is_false(ListFonts.containsGujarati(""))
        assert.is_false(ListFonts.containsGujarati("Hello world"))
        -- "ગુજરાતી" (Gujarati)
        assert.is_true(ListFonts.containsGujarati("ગુજરાતી news"))
        assert.is_true(ListFonts.containsGujarati("English · ગુજરાતી"))
    end)

    it("normalizes font keys for matching", function()
        assert.equals("robotocondensedregular", ListFonts.normalizeFontKey("Roboto-Condensed-Regular.ttf"))
        assert.equals("notoserifgujarati", ListFonts.normalizeFontKey("/fonts/Noto Serif Gujarati.ttf"))
        assert.equals("", ListFonts.normalizeFontKey(nil))
        assert.is_true(ListFonts.normalizeFontKey("RobotoCondensed-Regular.ttf"):find("robotocondensed", 1, true) ~= nil)
    end)

    it("matches font paths against hints", function()
        assert.is_true(ListFonts.pathMatchesHints(
            "/usr/fonts/RobotoCondensed-Regular.ttf",
            ListFonts.LATIN_HINTS
        ))
        assert.is_true(ListFonts.pathMatchesHints(
            "NotoSerifGujarati-Regular.ttf",
            ListFonts.GUJARATI_HINTS
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
            "/fonts/NotoSerifGujarati-Bold.ttf",
            "/fonts/NotoSerifGujarati-Regular.ttf",
        }
        assert.equals("/fonts/RobotoCondensed-Regular.ttf", ListFonts.findInstalledFont(ListFonts.LATIN_HINTS, fonts))
        assert.equals("/fonts/NotoSerifGujarati-Regular.ttf", ListFonts.findInstalledFont(ListFonts.GUJARATI_HINTS, fonts))
    end)

    it("resolves saved settings over auto-detect", function()
        local fonts = { "/fonts/RobotoCondensed-Regular.ttf", "/fonts/NotoSerifGujarati-Regular.ttf" }
        assert.equals("/fonts/RobotoCondensed-Regular.ttf", ListFonts.resolveLatinFont(fonts))
        ListFonts.saveLatinFont("/custom/Latin.ttf")
        assert.equals("/custom/Latin.ttf", ListFonts.resolveLatinFont(fonts))
        ListFonts.saveLatinFont(nil)
        assert.equals("/fonts/RobotoCondensed-Regular.ttf", ListFonts.resolveLatinFont(fonts))
    end)

    it("persists gujarati font setting", function()
        assert.is_nil(ListFonts.readGujaratiFont())
        ListFonts.saveGujaratiFont("/fonts/NotoSerifGujarati-Regular.ttf")
        assert.equals("/fonts/NotoSerifGujarati-Regular.ttf", ListFonts.readGujaratiFont())
        ListFonts.saveGujaratiFont(nil)
        assert.is_nil(ListFonts.readGujaratiFont())
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

    it("builds missing-font hint when preferred fonts absent", function()
        local msg = ListFonts.missingFontsHint({})
        assert.truthy(msg:find("Roboto Condensed", 1, true))
        assert.truthy(msg:find("Noto Serif Gujarati", 1, true))
        local fonts = {
            "/fonts/RobotoCondensed-Regular.ttf",
            "/fonts/NotoSerifGujarati-Regular.ttf",
        }
        assert.is_nil(ListFonts.missingFontsHint(fonts))
        local shown = {}
        assert.is_true(ListFonts.maybeShowMissingHint(function(m) shown[#shown + 1] = m end, {}))
        assert.equals(1, #shown)
        assert.is_false(ListFonts.maybeShowMissingHint(function() end, {}))
    end)

    it("injects and restores Gujarati fallback without touching smallinfofont", function()
        package.loaded["ui/font"] = nil
        local latin_path = os.tmpname()
        local guj_path = os.tmpname()
        local f1 = assert(io.open(latin_path, "wb")); f1:write("x"); f1:close()
        local f2 = assert(io.open(guj_path, "wb")); f2:write("x"); f2:close()
        package.preload["ui/font"] = function()
            return {
                fontmap = { smallinfofont = "NotoSans-Regular.ttf" },
                fallbacks = {
                    "NotoSans-Regular.ttf",
                    "NotoSansCJKsc-Regular.otf",
                },
                faces = {},
            }
        end
        ListFonts.saveLatinFont(latin_path)
        ListFonts.saveGujaratiFont(guj_path)
        ListFonts.apply()
        local Font = require("ui/font")
        assert.equals("NotoSans-Regular.ttf", Font.fontmap.smallinfofont)
        assert.equals(guj_path, Font.fallbacks[2])
        ListFonts.restore()
        assert.equals("NotoSans-Regular.ttf", Font.fontmap.smallinfofont)
        assert.equals("NotoSansCJKsc-Regular.otf", Font.fallbacks[2])
        package.preload["ui/font"] = nil
        package.loaded["ui/font"] = nil
        os.remove(latin_path)
        os.remove(guj_path)
    end)
end)
