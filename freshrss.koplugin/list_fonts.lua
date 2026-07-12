-- Article-list fonts: Latin primary face + Gujarati via Font.fallbacks.
-- Latin is applied per Menu update (list_menu.lua) without remapping global
-- smallinfofont; only Gujarati fallback injection touches shared Font state.

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
ListFonts.DEVANAGARI_HINTS = {
    "notosansdevanagari",
    "noto sans devanagari",
    "notoserifdevanagari",
    "noto serif devanagari",
    "devanagari",
    "hindi",
}

-- Viewer @font-face settings (MuPDF CSS only — never remaps Font.fontmap).
ListFonts.SETTING_VIEWER_LATIN = "freshrss_viewer_font_latin"
ListFonts.SETTING_VIEWER_DEVANAGARI = "freshrss_viewer_font_devanagari"
ListFonts.SETTING_VIEWER_GUJARATI = "freshrss_viewer_font_gujarati"
-- Legacy single-font setting maps to Latin when viewer_latin unset.
ListFonts.SETTING_VIEWER_LEGACY = "freshrss_viewer_font_face"

-- Session overrides while FreshRSS home is open (Gujarati fallback only).
local _session = {
    applied = false,
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

---Devanagari block U+0900–U+097F as UTF-8: E0 A4 80 .. E0 A5 BF.
function ListFonts.containsDevanagari(text)
    if type(text) ~= "string" or text == "" then return false end
    return text:find("\224[\164-\165][\128-\191]") ~= nil
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
    local name = path:match("([^/\\]+)$") or path
    name = name:gsub("%.%w+$", "") -- strip extension
    name = name:gsub("%-?VariableFont[_%-]?[%w]*", "")
    name = name:gsub("[_%-]+$", "")
    name = name:gsub("[_%-]+", " ")
    if name == "" then
        name = path:match("([^/\\]+)$") or path
    end
    return name
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

local function readViewerSetting(key)
    local face = G_reader_settings:readSetting(key)
    if type(face) == "string" and face ~= "" then return face end
    return nil
end

local function saveViewerSetting(key, face)
    if face and face ~= "" then
        G_reader_settings:saveSetting(key, face)
    else
        G_reader_settings:delSetting(key)
    end
    G_reader_settings:flush()
end

function ListFonts.readViewerLatinFont()
    return readViewerSetting(ListFonts.SETTING_VIEWER_LATIN)
        or readViewerSetting(ListFonts.SETTING_VIEWER_LEGACY)
end

function ListFonts.readViewerDevanagariFont()
    return readViewerSetting(ListFonts.SETTING_VIEWER_DEVANAGARI)
end

function ListFonts.readViewerGujaratiFont()
    return readViewerSetting(ListFonts.SETTING_VIEWER_GUJARATI)
end

function ListFonts.saveViewerLatinFont(face)
    saveViewerSetting(ListFonts.SETTING_VIEWER_LATIN, face)
    if face and face ~= "" then
        saveViewerSetting(ListFonts.SETTING_VIEWER_LEGACY, face)
    else
        G_reader_settings:delSetting(ListFonts.SETTING_VIEWER_LEGACY)
        G_reader_settings:flush()
    end
end

function ListFonts.saveViewerDevanagariFont(face)
    saveViewerSetting(ListFonts.SETTING_VIEWER_DEVANAGARI, face)
end

function ListFonts.saveViewerGujaratiFont(face)
    saveViewerSetting(ListFonts.SETTING_VIEWER_GUJARATI, face)
end

function ListFonts.resolveViewerLatinFont(font_list)
    local saved = ListFonts.readViewerLatinFont()
    if saved then return saved end
    return ListFonts.findInstalledFont(ListFonts.LATIN_HINTS, font_list)
end

function ListFonts.resolveViewerDevanagariFont(font_list)
    local saved = ListFonts.readViewerDevanagariFont()
    if saved then return saved end
    return ListFonts.findInstalledFont(ListFonts.DEVANAGARI_HINTS, font_list)
end

function ListFonts.resolveViewerGujaratiFont(font_list)
    local saved = ListFonts.readViewerGujaratiFont()
    if saved then return saved end
    return ListFonts.findInstalledFont(ListFonts.GUJARATI_HINTS, font_list)
end

---Escape a filesystem path for MuPDF @font-face url('…').
local function cssFontUrl(path)
    return tostring(path or ""):gsub("'", "")
end

---Emit @font-face rules + font-family stack for MuPDF article CSS.
-- @param opts table|nil { latin, devanagari, gujarati } absolute paths
-- @return string css fragment (may be empty)
function ListFonts.buildViewerFontCss(opts)
    opts = opts or {}
    local latin = opts.latin
    local devanagari = opts.devanagari
    local gujarati = opts.gujarati
    if not latin and not devanagari and not gujarati then return "" end

    local families = {}
    local css = ""
    if latin and latin ~= "" then
        css = css .. string.format(
            "@font-face { font-family: 'FreshRSSLatin'; src: url('%s'); }\n",
            cssFontUrl(latin)
        )
        table.insert(families, "'FreshRSSLatin'")
    end
    if devanagari and devanagari ~= "" then
        css = css .. string.format(
            "@font-face { font-family: 'FreshRSSDevanagari'; src: url('%s'); }\n",
            cssFontUrl(devanagari)
        )
        table.insert(families, "'FreshRSSDevanagari'")
    end
    if gujarati and gujarati ~= "" then
        css = css .. string.format(
            "@font-face { font-family: 'FreshRSSGujarati'; src: url('%s'); }\n",
            cssFontUrl(gujarati)
        )
        table.insert(families, "'FreshRSSGujarati'")
    end
    if #families > 0 then
        css = css .. "body { font-family: " .. table.concat(families, ", ") .. "; }\n"
    end
    return css
end

---Resolved viewer font paths (auto-detect when unset).
function ListFonts.resolveViewerFonts(font_list)
    return {
        latin = ListFonts.resolveViewerLatinFont(font_list),
        devanagari = ListFonts.resolveViewerDevanagariFont(font_list),
        gujarati = ListFonts.resolveViewerGujaratiFont(font_list),
    }
end

---Settings row label for a viewer script font.
function ListFonts.viewerFontLabel(kind, font_list)
    local path, saved, prefix
    if kind == "devanagari" then
        saved = ListFonts.readViewerDevanagariFont()
        path = saved or ListFonts.resolveViewerDevanagariFont(font_list)
        prefix = "Viewer font (Hindi): "
    elseif kind == "gujarati" then
        saved = ListFonts.readViewerGujaratiFont()
        path = saved or ListFonts.resolveViewerGujaratiFont(font_list)
        prefix = "Viewer font (Gujarati): "
    else
        saved = ListFonts.readViewerLatinFont()
        path = saved or ListFonts.resolveViewerLatinFont(font_list)
        prefix = "Viewer font (Latin): "
        -- Treat legacy-only path as explicit, not auto.
        if not readViewerSetting(ListFonts.SETTING_VIEWER_LATIN)
            and readViewerSetting(ListFonts.SETTING_VIEWER_LEGACY) then
            return prefix .. ListFonts.displayName(path)
        end
    end
    if not saved and path then
        return prefix .. "auto · " .. ListFonts.displayName(path)
    end
    return prefix .. ListFonts.displayName(path)
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

local function fontFileExists(path)
    if type(path) ~= "string" or path == "" then return false end
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

---Ensure Gujarati is in Font.fallbacks while home is open (Latin is scoped in list_menu).
function ListFonts.apply()
    local Font = require("ui/font")

    if _session.injected_fallback then
        removeFallback(Font.fallbacks, _session.injected_fallback)
        _session.injected_fallback = nil
    end

    local gujarati = ListFonts.resolveGujaratiFont()
    if gujarati and not fontFileExists(gujarati) then
        gujarati = nil
    end
    if gujarati and not fallbackHas(Font.fallbacks, gujarati) then
        local insert_at = 2
        if insert_at > #Font.fallbacks + 1 then insert_at = #Font.fallbacks + 1 end
        table.insert(Font.fallbacks, insert_at, gujarati)
        _session.injected_fallback = gujarati
    end

    _session.applied = true
end

---Restore Gujarati fallback injection after home closes.
function ListFonts.restore()
    if not _session.applied then return end
    local Font = require("ui/font")
    if _session.injected_fallback then
        removeFallback(Font.fallbacks, _session.injected_fallback)
    end
    _session.applied = false
    _session.injected_fallback = nil
    _session.hint_shown = false
end

---Test helper: reset session without touching Font (specs).
function ListFonts._resetSessionForTests()
    _session.applied = false
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
