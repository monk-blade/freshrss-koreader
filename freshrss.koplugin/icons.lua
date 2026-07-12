-- Resolve and install Lucide SVG icons for KOReader's icon name lookup.
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local Icons = {}
Icons.__index = Icons

local ICON_FILES = {
    refresh = "refresh.svg",
    star = "star.svg",
    book_open = "book-open.svg",
    settings = "settings.svg",
    inbox = "inbox.svg",
    wifi_off = "wifi-off.svg",
    circle = "circle.svg",
    check_circle = "check-circle.svg",
}

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

-- IconWidget / TitleBar name (looked up under DataStorage/icons/).
function Icons:name(key)
    return "freshrss." .. key:gsub("_", "-")
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
