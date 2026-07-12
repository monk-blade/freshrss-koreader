-- Favorite FreshRSS category (label) shortcuts for the home chrome row.
local FavCategories = {}

FavCategories.SETTING = "freshrss_favorite_categories"
FavCategories.MAX = 8

---Lucide keys offered in the category icon picker (must exist in icons.lua).
FavCategories.ICON_PALETTE = {
    "newspaper", "briefcase", "cpu", "globe", "book", "heart",
    "inbox", "star", "rss", "tag", "bookmark", "layers",
    "folder", "music", "gamepad_2", "image", "type", "plug",
}

function FavCategories.labelDisplayName(label_id)
    local name = tostring(label_id or "")
    return name:gsub("^user/%-/label/", "")
end

---Two-letter tile text from a category display name (Unicode-safe).
---KOReader has no Lua `utf8` module; never byte-slice (breaks Gujarati → FreeType crash).
function FavCategories.twoLetters(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("%s+", "")
    if name == "" then return "??" end
    local chars
    local ok_util, util = pcall(require, "util")
    if ok_util and util and util.splitToChars then
        chars = util.splitToChars(name)
    else
        -- Same idea as util.UTF8_CHAR_PATTERN (no KOReader util in unit tests).
        chars = {}
        for uchar in name:gmatch("([%z\1-\127\194-\244][\128-\191]*)") do
            table.insert(chars, uchar)
        end
    end
    if type(chars) ~= "table" or #chars == 0 then
        return "??"
    end
    local function tileChar(c)
        c = tostring(c or "")
        if c == "" then return "?" end
        -- string.upper is only safe for single-byte ASCII
        if #c == 1 and c:match("%a") then
            return c:upper()
        end
        return c
    end
    local a = tileChar(chars[1])
    local b = tileChar(chars[2] or chars[1])
    return a .. b
end

function FavCategories.read(settings)
    local raw = settings and settings.readSetting and settings:readSetting(FavCategories.SETTING)
    local out = {}
    if type(raw) ~= "table" then return out end
    for _, row in ipairs(raw) do
        if type(row) == "table" and row.id and tostring(row.id) ~= "" then
            table.insert(out, {
                id = tostring(row.id),
                icon = row.icon and tostring(row.icon) or nil,
            })
            if #out >= FavCategories.MAX then break end
        elseif type(row) == "string" and row ~= "" then
            table.insert(out, { id = row, icon = nil })
            if #out >= FavCategories.MAX then break end
        end
    end
    return out
end

function FavCategories.save(settings, list)
    list = list or {}
    local trimmed = {}
    for _, row in ipairs(list) do
        if row and row.id then
            table.insert(trimmed, {
                id = tostring(row.id),
                icon = row.icon and tostring(row.icon) or nil,
            })
            if #trimmed >= FavCategories.MAX then break end
        end
    end
    settings:saveSetting(FavCategories.SETTING, trimmed)
    if settings.flush then settings:flush() end
    return trimmed
end

function FavCategories.isFavorite(settings, label_id)
    label_id = tostring(label_id or "")
    for _, row in ipairs(FavCategories.read(settings)) do
        if row.id == label_id then return true end
    end
    return false
end

function FavCategories.add(settings, label_id, icon)
    label_id = tostring(label_id or "")
    if label_id == "" then return FavCategories.read(settings) end
    local list = FavCategories.read(settings)
    for _, row in ipairs(list) do
        if row.id == label_id then
            if icon ~= nil then row.icon = icon end
            return FavCategories.save(settings, list)
        end
    end
    if #list >= FavCategories.MAX then return list end
    table.insert(list, { id = label_id, icon = icon })
    return FavCategories.save(settings, list)
end

function FavCategories.remove(settings, label_id)
    label_id = tostring(label_id or "")
    local list = FavCategories.read(settings)
    local next_list = {}
    for _, row in ipairs(list) do
        if row.id ~= label_id then table.insert(next_list, row) end
    end
    return FavCategories.save(settings, next_list)
end

function FavCategories.setIcon(settings, label_id, icon)
    label_id = tostring(label_id or "")
    local list = FavCategories.read(settings)
    for _, row in ipairs(list) do
        if row.id == label_id then
            row.icon = icon and tostring(icon) or nil
            break
        end
    end
    return FavCategories.save(settings, list)
end

---Labels available from sync meta (FreshRSS tag list).
function FavCategories.availableLabels(cache)
    local labels = {}
    if not cache or not cache.getMeta then return labels end
    local meta = cache:getMeta()
    local tags = meta.tags and meta.tags.tags or {}
    for _, tag in ipairs(tags) do
        local id = tag.id
        if type(id) == "string" and id:find("user/%-/label/", 1, false) then
            table.insert(labels, id)
        end
    end
    table.sort(labels, function(a, b)
        return FavCategories.labelDisplayName(a) < FavCategories.labelDisplayName(b)
    end)
    return labels
end

return FavCategories
