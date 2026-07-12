-- Article-list fonts: Latin primary face + Gujarati via Font.fallbacks.
-- KOReader Menu/MenuItem use a single face ("smallinfofont"); there is no
-- per-item font. Missing glyphs fall through Font.fallbacks (Xtext/HarfBuzz).

local ListFonts = {}

ListFonts.SETTING_LATIN = "freshrss_list_font_latin"
ListFonts.SETTING_GUJARATI = "freshrss_list_font_gujarati"
ListFonts.SETTING_SIZE = "freshrss_list_font_size"
-- MenuItem default in frontend/ui/widget/menu.lua
ListFonts.MENU_FACE = "smallinfofont"
-- Match viewer body SpinWidget range; default near Menu adaptive size (~19–22).
ListFonts.DEFAULT_SIZE = 20
ListFonts.SIZE_MIN = 12
ListFonts.SIZE_MAX = 36

-- Prefer these name substrings when settings are empty (normalized match).
ListFonts.LATIN_HINTS = {
    "robotocondensed",
    "roboto condensed",
}
ListFonts.GUJARATI_HINTS = {
    "notoserifgujarati",
    "noto serif gujarati",
    "notosansgujarati",
    "noto sans gujarati",
    "gujarati",
}

-- Session overrides while FreshRSS home is open (restore on close).
local _session = {
    applied = false,
    saved_fontmap = nil,
    injected_fallback = nil,
    hint_shown = false,
}

---Normalize a font path/filename for substring matching.
function ListFonts.normalizeFontKey(path)
    if type(path) ~= "string" or path == "" then return "" end
    local name = path:match("([^/\\]+)$") or path
    name = name:lower()
    -- Drop extension and separators so "Roboto-Condensed" ≈ "robotocondensed".
    name = name:gsub("%.[^%.]+$", "")
    name = name:gsub("[%s%-%_]+", "")
    return name
end

---True if path/filename matches any hint (normalized substring).
function ListFonts.pathMatchesHints(path, hints)
    if type(path) ~= "string" or type(hints) ~= "table" then return false end
    local key = ListFonts.normalizeFontKey(path)
    if key == "" then return false end
    for _, hint in ipairs(hints) do
        local h = ListFonts.normalizeFontKey(hint)
        if h ~= "" and key:find(h, 1, true) then
            return true
        end
    end
    return false
end

local function looksStyled(path)
    local key = ListFonts.normalizeFontKey(path)
    return key:find("bold", 1, true)
        or key:find("italic", 1, true)
        or key:find("oblique", 1, true)
end

---Gujarati block U+0A80–U+0AFF as UTF-8: E0 AA 80 .. E0 AB BF.
function ListFonts.containsGujarati(text)
    if type(text) ~= "string" or text == "" then return false end
    return text:find("\224[\170-\171][\128-\191]") ~= nil
end

function ListFonts.readLatinFont()
    local face = G_reader_settings:readSetting(ListFonts.SETTING_LATIN)
    if type(face) == "string" and face ~= "" then return face end
    return nil
end

function ListFonts.readGujaratiFont()
    local face = G_reader_settings:readSetting(ListFonts.SETTING_GUJARATI)
    if type(face) == "string" and face ~= "" then return face end
    return nil
end

function ListFonts.saveLatinFont(face)
    if face and face ~= "" then
        G_reader_settings:saveSetting(ListFonts.SETTING_LATIN, face)
    else
        G_reader_settings:delSetting(ListFonts.SETTING_LATIN)
    end
    G_reader_settings:flush()
end

function ListFonts.saveGujaratiFont(face)
    if face and face ~= "" then
        G_reader_settings:saveSetting(ListFonts.SETTING_GUJARATI, face)
    else
        G_reader_settings:delSetting(ListFonts.SETTING_GUJARATI)
    end
    G_reader_settings:flush()
end

function ListFonts.clampFontSize(size)
    size = tonumber(size) or ListFonts.DEFAULT_SIZE
    if size < ListFonts.SIZE_MIN then size = ListFonts.SIZE_MIN end
    if size > ListFonts.SIZE_MAX then size = ListFonts.SIZE_MAX end
    return math.floor(size + 0.5)
end

function ListFonts.readFontSize()
    local size = tonumber(G_reader_settings:readSetting(ListFonts.SETTING_SIZE))
    if not size then return ListFonts.DEFAULT_SIZE end
    return ListFonts.clampFontSize(size)
end

function ListFonts.saveFontSize(size)
    G_reader_settings:saveSetting(ListFonts.SETTING_SIZE, ListFonts.clampFontSize(size))
    G_reader_settings:flush()
end

---Short label for settings rows.
function ListFonts.displayName(path)
    if not path or path == "" then return "Default" end
    return path:match("([^/\\]+)$") or path
end

---Find first installed font matching hints (regular preferred).
-- @param hints string[]
-- @param font_list string[]|nil optional (defaults to FontList)
function ListFonts.findInstalledFont(hints, font_list)
    if not font_list then
        local ok, FontList = pcall(require, "fontlist")
        if not ok or not FontList then return nil end
        font_list = FontList:getFontList() or {}
    end
    local regular_hit, any_hit
    for _, hint in ipairs(hints or {}) do
        local hnorm = ListFonts.normalizeFontKey(hint)
        if hnorm ~= "" then
            for _, path in ipairs(font_list) do
                if ListFonts.pathMatchesHints(path, { hint }) then
                    if not looksStyled(path) then
                        return path
                    end
                    any_hit = any_hit or path
                end
            end
        end
        regular_hit = regular_hit or any_hit
        any_hit = nil
    end
    return regular_hit
end

---Resolved Latin font path, or nil to keep KOReader default Menu face.
function ListFonts.resolveLatinFont(font_list)
    local saved = ListFonts.readLatinFont()
    if saved then return saved end
    return ListFonts.findInstalledFont(ListFonts.LATIN_HINTS, font_list)
end

---Resolved Gujarati font path for fallback injection, or nil.
function ListFonts.resolveGujaratiFont(font_list)
    local saved = ListFonts.readGujaratiFont()
    if saved then return saved end
    return ListFonts.findInstalledFont(ListFonts.GUJARATI_HINTS, font_list)
end

local function fallbackHas(fallbacks, path)
    if not path then return false end
    local want = ListFonts.normalizeFontKey(path)
    for _, entry in ipairs(fallbacks) do
        if entry == path or ListFonts.normalizeFontKey(entry) == want then
            return true
        end
    end
    return false
end

local function removeFallback(fallbacks, path)
    if not path then return end
    local want = ListFonts.normalizeFontKey(path)
    for i = #fallbacks, 1, -1 do
        local entry = fallbacks[i]
        if entry == path or ListFonts.normalizeFontKey(entry) == want then
            table.remove(fallbacks, i)
            return
        end
    end
end

local function clearFaceFallbackCaches(Font)
    if not Font or not Font.faces then return end
    for _, face in pairs(Font.faces) do
        face.fallbacks = nil
    end
end

---Remap Menu face + ensure Gujarati in Font.fallbacks while home is open.
function ListFonts.apply()
    local Font = require("ui/font")
    if not _session.applied then
        _session.saved_fontmap = Font.fontmap[ListFonts.MENU_FACE]
    end

    local latin = ListFonts.resolveLatinFont()
    if latin then
        Font.fontmap[ListFonts.MENU_FACE] = latin
    else
        Font.fontmap[ListFonts.MENU_FACE] = _session.saved_fontmap
    end

    -- Drop a previous injection before re-resolving.
    if _session.injected_fallback then
        removeFallback(Font.fallbacks, _session.injected_fallback)
        _session.injected_fallback = nil
    end

    local gujarati = ListFonts.resolveGujaratiFont()
    if gujarati and not fallbackHas(Font.fallbacks, gujarati) then
        -- After primary UI sans (index 1); HarfBuzz walks fallbacks for missing glyphs.
        local insert_at = 2
        if insert_at > #Font.fallbacks + 1 then insert_at = #Font.fallbacks + 1 end
        table.insert(Font.fallbacks, insert_at, gujarati)
        _session.injected_fallback = gujarati
    end

    clearFaceFallbackCaches(Font)
    _session.applied = true
end

---Restore fontmap / fallbacks after home closes.
function ListFonts.restore()
    if not _session.applied then return end
    local Font = require("ui/font")
    if _session.saved_fontmap ~= nil then
        Font.fontmap[ListFonts.MENU_FACE] = _session.saved_fontmap
    end
    if _session.injected_fallback then
        removeFallback(Font.fallbacks, _session.injected_fallback)
        clearFaceFallbackCaches(Font)
    end
    _session.applied = false
    _session.saved_fontmap = nil
    _session.injected_fallback = nil
    _session.hint_shown = false
end

---Test helper: reset session without touching Font (specs).
function ListFonts._resetSessionForTests()
    _session.applied = false
    _session.saved_fontmap = nil
    _session.injected_fallback = nil
    _session.hint_shown = false
end

---Message when preferred Latin/Gujarati fonts are not installed (nil if OK).
function ListFonts.missingFontsHint(font_list)
    local missing = {}
    if not ListFonts.resolveLatinFont(font_list) then
        table.insert(missing, "Roboto Condensed (Latin list titles)")
    end
    if not ListFonts.resolveGujaratiFont(font_list) then
        table.insert(missing, "Noto Serif Gujarati (Gujarati glyphs)")
    end
    if #missing == 0 then return nil end
    return "For clearer article-list fonts, install in KOReader’s fonts folder:\n• "
        .. table.concat(missing, "\n• ")
        .. "\nThen pick them under Settings → List font."
end

---Show missing-font hint at most once per home session.
function ListFonts.maybeShowMissingHint(show_fn, font_list)
    if _session.hint_shown then return false end
    local msg = ListFonts.missingFontsHint(font_list)
    if not msg then return false end
    _session.hint_shown = true
    if show_fn then show_fn(msg) end
    return true
end

return ListFonts
