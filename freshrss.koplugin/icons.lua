-- Resolve and install Lucide SVG icons for KOReader's icon name lookup.
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local Icons = {}
Icons.__index = Icons

local ICON_FILES = {
    freshrss = "freshrss.svg",
    refresh = "refresh.svg",
    star = "star.svg",
    star_filled = "star-filled.svg",
    book_open = "book-open.svg",
    settings = "settings.svg",
    inbox = "inbox.svg",
    wifi_off = "wifi-off.svg",
    circle = "circle.svg",
    check_circle = "check-circle.svg",
    chevron_left = "chevron-left.svg",
    chevron_right = "chevron-right.svg",
    list_filter = "list-filter.svg",
}

local function buttonIconSize()
    local ok, Device = pcall(require, "device")
    if ok and Device and Device.screen then
        return Device.screen:scaleBySize(24)
    end
    return 24
end

function Icons:new(plugin_dir)
    local o = setmetatable({
        plugin_dir = plugin_dir,
        assets_dir = plugin_dir .. "/assets/icons",
        installed = false,
    }, self)
    return o
end

function Icons:path(key)
    local file = ICON_FILES[key]
    if not file then return nil end
    return self.assets_dir .. "/" .. file
end

-- IconWidget / TitleBar / Button name (looked up under DataStorage/icons/).
function Icons:name(key)
    return "freshrss." .. key:gsub("_", "-")
end

-- ButtonTable entry helper: icon-only action with shared size across home/viewer.
function Icons:button(key, opts)
    opts = opts or {}
    local size = opts.size or buttonIconSize()
    local entry = {
        icon = self:name(key),
        icon_width = size,
        icon_height = size,
        callback = opts.callback,
    }
    if opts.enabled ~= nil then
        entry.enabled = opts.enabled
    end
    if opts.hold_callback then
        entry.hold_callback = opts.hold_callback
    end
    if opts.allow_hold_when_disabled then
        entry.allow_hold_when_disabled = opts.allow_hold_when_disabled
    end
    return entry
end

function Icons:install()
    if self.installed then return end
    local dest_dir = DataStorage:getDataDir() .. "/icons"
    lfs.mkdir(dest_dir)
    for key, file in pairs(ICON_FILES) do
        local src = self.assets_dir .. "/" .. file
        local dest = dest_dir .. "/" .. self:name(key) .. ".svg"
        local src_file = io.open(src, "rb")
        if src_file then
            local data = src_file:read("*a")
            src_file:close()
            local dest_file = io.open(dest, "wb")
            if dest_file then
                dest_file:write(data)
                dest_file:close()
            end
        end
    end
    self.installed = true
end

return Icons
