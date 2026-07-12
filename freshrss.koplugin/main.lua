local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Menu = require("ui/widget/menu")
local DataStorage = require("datastorage")
local util = require("util")

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")
local API = dofile(plugin_dir .. "/api.lua")
local Cache = dofile(plugin_dir .. "/cache.lua")
local Sync = dofile(plugin_dir .. "/sync.lua")
local Renderer = dofile(plugin_dir .. "/renderer.lua")

local Plugin = WidgetContainer:extend{
    name = "freshrss",
    is_doc_only = false,
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
    self.api_client = nil
    self.menu = nil
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

function Plugin:openHome()
    if trim(self:config().base_url) == "" then
        self:showSetup()
        return
    end
    self:refreshAndShow(nil, true)
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

function Plugin:refreshAndShow(feed_id, show_loading)
    local loading
    if show_loading then
        loading = InfoMessage:new{ text = "Syncing FreshRSS…" }
        UIManager:show(loading)
    end
    local function done(ok, result)
        if loading then UIManager:close(loading) end
        if not ok then
            UIManager:show(InfoMessage:new{ text = "FreshRSS unavailable:\n" .. tostring(result) })
            self:showCached(feed_id)
            return
        end
        self:showCached(feed_id)
    end
    local api = self:api()
    -- HTTPClient only works when the Turbo looper is active (DUSE_TURBO_LIB).
    -- initLooper always exists as a method; check the looper instance itself.
    UIManager:initLooper()
    if UIManager.looper then
        self.sync:refreshAsync(api, feed_id, done)
    else
        done(self.sync:refresh(api, feed_id))
    end
end

function Plugin:showCached(feed_id)
    local items = self.cache:listArticles(feed_id)
    local entries = {}
    for _, article in ipairs(items) do
        local marker = article.unread and "● " or "○ "
        local star = article.starred and " ★" or ""
        table.insert(entries, {
            text = marker .. articleTitle(article) .. star,
            mandatory = article.feed_title,
            callback = function() self:openArticle(article.id) end,
        })
    end
    if #entries == 0 then
        table.insert(entries, { text = "No cached articles. Tap Refresh to sync.", select_enabled = false })
    end
    table.insert(entries, 1, {
        text = "Refresh",
        callback = function() UIManager:close(self.menu); self:refreshAndShow(feed_id, true) end,
    })
    table.insert(entries, 2, {
        text = "Settings",
        callback = function() UIManager:close(self.menu); self:showSetup() end,
    })
    self.menu = Menu:new{
        title = "FreshRSS  ·  " .. tostring(self.cache:unreadCount()),
        title_multilines = true,
        multilines_show_more_text = true,
        item_table = entries,
        -- Keep Menu's default onMenuChoice so item.callback() runs on select.
        close_callback = function() self.menu = nil end,
    }
    UIManager:show(self.menu)
end

function Plugin:openArticle(id)
    local article = self.cache:getArticle(id)
    if not article then return end
    -- Update local state and paint the viewer first; sync read-state after paint
    -- so a slow FreshRSS round-trip cannot hang the UI before the article shows.
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
