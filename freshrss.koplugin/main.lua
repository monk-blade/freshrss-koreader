local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local NetworkMgr = require("ui/network/manager")
local DataStorage = require("datastorage")
local util = require("util")

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")
local API = dofile(plugin_dir .. "/api.lua")
local Cache = dofile(plugin_dir .. "/cache.lua")
local Sync = dofile(plugin_dir .. "/sync.lua")
local Renderer = dofile(plugin_dir .. "/renderer.lua")
local Icons = dofile(plugin_dir .. "/icons.lua")
local Status = dofile(plugin_dir .. "/ui_status.lua")

local Plugin = WidgetContainer:extend{
    name = "freshrss",
    is_doc_only = false,
}

local STAGE_LABELS = {
    login = "Signing in…",
    meta = "Loading feeds…",
    stream = "Fetching articles…",
    cache = "Updating cache…",
    done = "Done",
}

local function trim(value)
    return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function envOrSetting(name, setting)
    return os.getenv(name) or setting or ""
end

local function articleTitle(article)
    return util.htmlEntitiesToUtf8(tostring(article.title or "Untitled"))
end

function Plugin:init()
    self.settings = G_reader_settings
    self.cache = Cache:new(DataStorage:getDataDir() .. "/freshrss")
    self.sync = Sync:new(self.cache, self.settings)
    self.icons = Icons:new(plugin_dir)
    self.icons:install()
    Status:setIcons(self.icons)
    self.api_client = nil
    self.menu = nil
    self.feed_id = nil
    self.syncing = false
    self:registerMenuEntries()
end

function Plugin:registerMenuEntries()
    self.ui.menu:registerToMainMenu(self)
end

function Plugin:addToMainMenu(menu_items)
    menu_items.freshrss = {
        text = "FreshRSS",
        sorting_hint = "tools",
        callback = function() self:openHome() end,
    }
end

function Plugin:config()
    return {
        base_url = envOrSetting("FRESHRSS_API_URL", self.settings:readSetting("base_url")),
        username = envOrSetting("FRESHRSS_USERNAME", self.settings:readSetting("username")),
        api_password = envOrSetting("FRESHRSS_API_PASSWORD", self.settings:readSetting("api_password")),
    }
end

function Plugin:autoRefreshEnabled()
    return self.settings:readSetting("freshrss_auto_refresh") ~= false
end

function Plugin:openHome()
    if trim(self:config().base_url) == "" then
        self:showSetup()
        return
    end
    -- Offline-first: paint cache immediately, never block on network.
    self:showCached(nil)
    if self:autoRefreshEnabled() then
        UIManager:nextTick(function()
            if NetworkMgr:isOnline() then
                self:startSync(nil, false)
            end
        end)
    end
end

function Plugin:showSetup()
    local dialog
    dialog = MultiInputDialog:new{
        title = "FreshRSS connection",
        fields = {
            {
                hint = "API address",
                text = envOrSetting("FRESHRSS_API_URL", self.settings:readSetting("base_url")),
            },
            {
                hint = "Username",
                text = envOrSetting("FRESHRSS_USERNAME", self.settings:readSetting("username")),
            },
            {
                hint = "API password",
                text = envOrSetting("FRESHRSS_API_PASSWORD", self.settings:readSetting("api_password")),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = "Cancel",
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = "Test & save",
                    callback = function()
                        local fields = dialog:getFields()
                        local base_url = trim(fields[1])
                        local username = trim(fields[2])
                        local password = fields[3] or ""
                        if base_url == "" or username == "" or password == "" then
                            UIManager:show(InfoMessage:new{ text = "API address, username, and API password are required." })
                            return
                        end
                        local api = API:new{ base_url = base_url, username = username, api_password = password }
                        local ok, err = api:login()
                        if not ok then
                            UIManager:show(InfoMessage:new{ text = "Connection failed:\n" .. tostring(err) })
                            return
                        end
                        if not os.getenv("FRESHRSS_API_URL") then self.settings:saveSetting("base_url", api.base_url) end
                        if not os.getenv("FRESHRSS_USERNAME") then self.settings:saveSetting("username", username) end
                        if not os.getenv("FRESHRSS_API_PASSWORD") then self.settings:saveSetting("api_password", password) end
                        self.settings:flush()
                        self.api_client = API:new(self:config())
                        UIManager:close(dialog)
                        self:openHome()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Plugin:api()
    if not self.api_client then self.api_client = API:new(self:config()) end
    return self.api_client
end

function Plugin:progressHandler()
    return function(stage, ratio)
        local label = STAGE_LABELS[stage] or "Syncing FreshRSS…"
        Status:update(label, ratio)
    end
end

function Plugin:startSync(feed_id, interactive)
    if self.syncing then return end
    self.syncing = true
    self.feed_id = feed_id
    Status:show(STAGE_LABELS.login, 0.05)

    local function done(ok, result)
        self.syncing = false
        Status:close()
        if not ok then
            if interactive then
                UIManager:show(InfoMessage:new{ text = "FreshRSS unavailable:\n" .. tostring(result) })
            else
                Notification:notify("FreshRSS sync failed", Notification.SOURCE_ALWAYS_SHOW)
            end
            return
        end
        local unread = self.cache:unreadCount()
        Notification:notify("Updated · " .. tostring(unread) .. " unread", Notification.SOURCE_ALWAYS_SHOW)
        if self.menu then
            self:showCached(feed_id)
        end
    end

    local api = self:api()
    local on_progress = self:progressHandler()
    UIManager:initLooper()
    if UIManager.looper then
        self.sync:refreshAsync(api, feed_id, done, on_progress)
    else
        -- Yield to the UI once so the status strip can paint before blocking I/O.
        UIManager:nextTick(function()
            done(self.sync:refresh(api, feed_id, on_progress))
        end)
    end
end

function Plugin:requestSync(feed_id)
    NetworkMgr:runWhenOnline(function()
        self:startSync(feed_id, true)
    end)
end

function Plugin:buildItemTable(feed_id)
    local items = self.cache:listArticles(feed_id)
    local entries = {}
    local unread_mark = "● "
    local read_mark = "○ "
    for _, article in ipairs(items) do
        local marker = article.unread and unread_mark or read_mark
        local star = article.starred and " ★" or ""
        table.insert(entries, {
            text = marker .. articleTitle(article) .. star,
            mandatory = article.feed_title,
            callback = function() self:openArticle(article.id) end,
        })
    end
    if #entries == 0 then
        local offline = not NetworkMgr:isOnline()
        local empty_text = offline
            and "No cached articles · offline. Connect and tap Refresh."
            or "No cached articles. Tap Refresh to sync."
        table.insert(entries, { text = empty_text, select_enabled = false })
    end
    table.insert(entries, 1, {
        text = "↻  Refresh",
        callback = function() self:requestSync(feed_id) end,
    })
    table.insert(entries, 2, {
        text = "⚙  Settings",
        callback = function() self:showSetup() end,
    })
    local auto = self:autoRefreshEnabled()
    table.insert(entries, 3, {
        text = auto and "Auto-refresh on open: on" or "Auto-refresh on open: off",
        callback = function()
            self.settings:saveSetting("freshrss_auto_refresh", not auto)
            self.settings:flush()
            self:showCached(feed_id)
        end,
    })
    return entries
end

function Plugin:menuTitle()
    return "FreshRSS  ·  " .. tostring(self.cache:unreadCount())
end

function Plugin:menuSubtitle()
    local last = self.settings:readSetting("freshrss_last_sync") or self.settings:readSetting("last_sync")
    if not last then return "Not synced yet" end
    return "Last sync · " .. os.date("%Y-%m-%d %H:%M", tonumber(last) or os.time())
end

function Plugin:showCached(feed_id)
    self.feed_id = feed_id
    local entries = self:buildItemTable(feed_id)
    local title = self:menuTitle()
    local subtitle = self:menuSubtitle()
    if self.menu then
        self.menu:switchItemTable(title, entries, nil, nil, subtitle)
        return
    end
    self.menu = Menu:new{
        title = title,
        subtitle = subtitle,
        title_multilines = true,
        multilines_show_more_text = true,
        item_table = entries,
        title_bar_left_icon = self.icons:name("refresh"),
        onLeftButtonTap = function()
            self:requestSync(self.feed_id)
        end,
        close_callback = function()
            Status:close()
            self.menu = nil
        end,
    }
    UIManager:show(self.menu)
end

function Plugin:openArticle(id)
    local article = self.cache:getArticle(id)
    if not article then return end
    article.unread = false
    self.cache:putArticle(article)
    local widget = Renderer:articleWidget(article, {
        on_back = function() end,
        on_unread = function()
            article.unread = true
            self.cache:putArticle(article)
            UIManager:nextTick(function()
                self.sync:applyAction(self:api(), id, "read", false)
            end)
        end,
        on_star = function()
            article.starred = not article.starred
            self.cache:putArticle(article)
            UIManager:nextTick(function()
                self.sync:applyAction(self:api(), id, "starred", article.starred)
            end)
        end,
    })
    UIManager:show(widget)
    UIManager:nextTick(function()
        self.sync:applyAction(self:api(), id, "read", true)
    end)
end

return Plugin
