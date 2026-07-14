-- Article-list Latin face (scoped in list_menu) + optional single viewer @font-face.
-- Never remaps global Font.faces; list Latin is applied per Menu updateItems only.

local ListFonts = {}

ListFonts.SETTING_LATIN = "freshrss_list_font_latin"
ListFonts.SETTING_SIZE = "freshrss_list_font_size"
-- MenuItem default in frontend/ui/widget/menu.lua
ListFonts.MENU_FACE = "smallinfofont"
-- Match viewer body SpinWidget range; default near Menu adaptive size (~19–22).
ListFonts.DEFAULT_SIZE = 20
ListFonts.SIZE_MIN = 12
ListFonts.SIZE_MAX = 36

-- Prefer these name substrings when auto-picking a list Latin font in the picker.
ListFonts.LATIN_HINTS = {
    "robotocondensed",
    "roboto condensed",
}

-- Single optional viewer font (MuPDF CSS @font-face only).
-- Also migrates legacy freshrss_viewer_font_latin when present.
ListFonts.SETTING_VIEWER = "freshrss_viewer_font_face"
ListFonts.SETTING_VIEWER_LATIN_LEGACY = "freshrss_viewer_font_latin"

-- Session flag so apply/restore remain safe no-ops for home open/close.
local _session = {
    applied = false,
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

function ListFonts.readLatinFont()
    local face = G_reader_settings:readSetting(ListFonts.SETTING_LATIN)
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

---Saved Latin list font, or nil to keep KOReader default Menu face.
---Does not scan FontList on the hot path (avoids Kindle hangs).
function ListFonts.resolveLatinFont(font_list)
    local saved = ListFonts.readLatinFont()
    if saved then return saved end
    if font_list then
        return ListFonts.findInstalledFont(ListFonts.LATIN_HINTS, font_list)
    end
    return nil
end

---Single optional viewer font path (legacy latin key migrates here).
function ListFonts.readViewerFont()
    local face = G_reader_settings:readSetting(ListFonts.SETTING_VIEWER)
    if type(face) == "string" and face ~= "" then return face end
    face = G_reader_settings:readSetting(ListFonts.SETTING_VIEWER_LATIN_LEGACY)
    if type(face) == "string" and face ~= "" then return face end
    return nil
end

function ListFonts.saveViewerFont(face)
    if face and face ~= "" then
        G_reader_settings:saveSetting(ListFonts.SETTING_VIEWER, face)
        G_reader_settings:delSetting(ListFonts.SETTING_VIEWER_LATIN_LEGACY)
    else
        G_reader_settings:delSetting(ListFonts.SETTING_VIEWER)
        G_reader_settings:delSetting(ListFonts.SETTING_VIEWER_LATIN_LEGACY)
    end
    G_reader_settings:flush()
end

---Normalize separators; resolve relative paths for MuPDF (FootnoteWidget-style).
function ListFonts.absoluteFontPath(path)
    if type(path) ~= "string" or path == "" then return nil end
    path = path:gsub("\\", "/")
    if not path:match("^/") and not path:match("^%a:[/\\]") then
        local ok, ffiUtil = pcall(require, "ffi/util")
        if ok and ffiUtil.realpath then
            local resolved = ffiUtil.realpath(path)
            if type(resolved) == "string" and resolved ~= "" then
                path = resolved:gsub("\\", "/")
            end
        end
    end
    return path
end

---Return an on-disk font path MuPDF can open, or nil.
-- @param path string saved or discovered font path
-- @param font_list string[]|nil FontList paths for basename fallback
function ListFonts.resolveFontPath(path, font_list)
    if type(path) ~= "string" or path == "" then return nil end

    local function readable(candidate)
        if type(candidate) ~= "string" or candidate == "" then return nil end
        candidate = candidate:gsub("\\", "/")
        local f = io.open(candidate, "rb")
        if f then
            f:close()
            return ListFonts.absoluteFontPath(candidate)
        end
        return nil
    end

    local hit = readable(path)
    if hit then return hit end

    local abs = ListFonts.absoluteFontPath(path)
    if abs and abs ~= path then
        hit = readable(abs)
        if hit then return hit end
    end

    local base = path:match("([^/\\]+)$") or path
    local want = ListFonts.normalizeFontKey(base)
    if want ~= "" and font_list then
        for _, candidate in ipairs(font_list) do
            local cb = candidate:match("([^/\\]+)$") or candidate
            if cb == base or ListFonts.normalizeFontKey(cb) == want then
                hit = readable(candidate)
                if hit then return hit end
            end
        end
    end

    return nil
end

---Settings row label for the optional viewer font.
function ListFonts.viewerFontLabel()
    local path = ListFonts.readViewerFont()
    if not path then
        return "Viewer font: Default"
    end
    return "Viewer font: " .. ListFonts.displayName(path)
end

---No-op retained so home open/close callers stay safe after Indic fallback removal.
function ListFonts.apply()
    _session.applied = true
end

---No-op pair for home close.
function ListFonts.restore()
    _session.applied = false
    _session.hint_shown = false
end

---Test helper: reset session without touching Font (specs).
function ListFonts._resetSessionForTests()
    _session.applied = false
    _session.hint_shown = false
end

---Optional hint when a preferred Latin list font is not installed (nil if OK).
---Pass an explicit font_list (possibly empty) to evaluate; nil skips the check
---so Appearance open does not scan FontList on every open.
function ListFonts.missingFontsHint(font_list)
    if font_list == nil then return nil end
    if ListFonts.readLatinFont() then return nil end
    if ListFonts.findInstalledFont(ListFonts.LATIN_HINTS, font_list) then
        return nil
    end
    return "For clearer article-list titles, install Roboto Condensed in KOReader’s fonts folder,\n"
        .. "then pick it under Settings → Appearance → List font."
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
