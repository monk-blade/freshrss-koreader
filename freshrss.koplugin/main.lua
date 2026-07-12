local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local NetworkMgr = require("ui/network/manager")
local Dispatcher = require("dispatcher")
local Device = require("device")
local DataStorage = require("datastorage")
local util = require("util")

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")
local API = dofile(plugin_dir .. "/api.lua")
local Cache = dofile(plugin_dir .. "/cache.lua")
local Sync = dofile(plugin_dir .. "/sync.lua")
local Renderer = dofile(plugin_dir .. "/renderer.lua")
local Images = dofile(plugin_dir .. "/images.lua")
local Icons = dofile(plugin_dir .. "/icons.lua")
local Status = dofile(plugin_dir .. "/ui_status.lua")
local Home = dofile(plugin_dir .. "/home.lua")

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

local MODE_LABELS = {
    unread = "Unread",
    all = "All",
    starred = "Starred",
    feed = "Feeds",
    label = "Categories",
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

local function labelDisplayName(label_id)
    local name = tostring(label_id or "")
    return name:gsub("^user/%-/label/", "")
end

function Plugin:init()
    self.settings = G_reader_settings
    self.cache = Cache:new(DataStorage:getDataDir() .. "/freshrss")
    self.sync = Sync:new(self.cache, self.settings)
    self.icons = Icons:new(plugin_dir)
    self.icons:install()
    Status:setIcons(self.icons)
    self.api_client = nil
    self.home = nil
    self.menu = nil -- alias to home.list when home is open
    self.settings_menu = nil
    self.queue_menu = nil
    self.browse_picker = nil
    self.viewer = nil
    self.syncing = false
    self:onDispatcherRegisterActions()
    self:registerMenuEntries()
end

function Plugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("freshrss_sync", {
        category = "none",
        event = "SynchronizeFreshRSS",
        title = "FreshRSS sync",
        general = true,
    })
    Dispatcher:registerAction("freshrss_flush_queue", {
        category = "none",
        event = "FlushFreshRSSQueue",
        title = "FreshRSS flush queue",
        general = true,
    })
    Dispatcher:registerAction("freshrss_open", {
        category = "none",
        event = "OpenFreshRSS",
        title = "Open FreshRSS",
        general = true,
    })
end

function Plugin:onSynchronizeFreshRSS()
    if trim(self:config().base_url) == "" then return true end
    self:requestSync()
    return true
end

function Plugin:onFlushFreshRSSQueue()
    self:flushQueueInteractive()
    return true
end

function Plugin:onOpenFreshRSS()
    self:openHome()
    return true
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
    -- Default off: only sync on open when the user explicitly enables it.
    return self.settings:readSetting("freshrss_auto_refresh") == true
end

function Plugin:syncUnreadOnly()
    local value = self.settings:readSetting("freshrss_sync_unread_only")
    if value == nil then return true end
    return value and true or false
end

function Plugin:articlesPerSync()
    local max = tonumber(self.settings:readSetting("freshrss_articles_per_sync")) or Sync.DEFAULT_ARTICLE_CAP
    return max
end

function Plugin:cycleArticlesPerSync()
    local current = self:articlesPerSync()
    local caps = Sync.ARTICLE_CAPS
    local next_cap = caps[1]
    for i, cap in ipairs(caps) do
        if cap == current and caps[i + 1] then
            next_cap = caps[i + 1]
            break
        elseif cap == current then
            next_cap = caps[1]
            break
        elseif current < cap then
            next_cap = cap
            break
        end
    end
    self.settings:saveSetting("freshrss_articles_per_sync", next_cap)
    self.settings:flush()
    return next_cap
end

function Plugin:browseState()
    local mode = self.settings:readSetting("freshrss_browse_mode") or "unread"
    return {
        mode = mode,
        feed_id = self.settings:readSetting("freshrss_browse_feed_id"),
        label = self.settings:readSetting("freshrss_browse_label"),
    }
end

function Plugin:setBrowseState(state)
    self.settings:saveSetting("freshrss_browse_mode", state.mode or "unread")
    if state.feed_id then
        self.settings:saveSetting("freshrss_browse_feed_id", state.feed_id)
    else
        self.settings:delSetting("freshrss_browse_feed_id")
    end
    if state.label then
        self.settings:saveSetting("freshrss_browse_label", state.label)
    else
        self.settings:delSetting("freshrss_browse_label")
    end
    self.settings:flush()
end

function Plugin:currentStreamId()
    return self.sync:streamIdForBrowse(self:browseState())
end

function Plugin:openHome()
    if trim(self:config().base_url) == "" then
        self:showSetup()
        return
    end
    self:showCached()
    if self:autoRefreshEnabled() then
        UIManager:nextTick(function()
            if NetworkMgr:isOnline() then
                self:startSync(false)
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

function Plugin:startSync(interactive)
    if self.syncing then return end
    self.syncing = true
    Status:show(STAGE_LABELS.login, 0.05)
    local browse = self:browseState()
    local stream_id = self.sync:streamIdForBrowse(browse)

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
        local fetched = result and result.fetched or 0
        local mode = (result and result.exclude_read) and "unread" or "all"
        local flushed = result and result.flushed or 0
        local failed = result and result.flush_failed or 0
        local msg = string.format("Updated · %d fetched (%s) · %d unread", fetched, mode, unread)
        if flushed > 0 or failed > 0 then
            msg = msg .. string.format(" · queue %d/%d", flushed, flushed + failed)
        end
        Notification:notify(msg, Notification.SOURCE_ALWAYS_SHOW)
        if self.home then
            self:showCached()
        end
    end

    local api = self:api()
    local on_progress = self:progressHandler()
    UIManager:initLooper()
    if UIManager.looper then
        self.sync:refreshAsync(api, stream_id, done, on_progress, browse)
    else
        UIManager:nextTick(function()
            done(self.sync:refresh(api, stream_id, on_progress, browse))
        end)
    end
end

function Plugin:requestSync()
    NetworkMgr:runWhenOnline(function()
        self:startSync(true)
    end)
end

function Plugin:flushQueueInteractive()
    NetworkMgr:runWhenOnline(function()
        local api = self:api()
        local ok = api:login()
        if not ok then
            UIManager:show(InfoMessage:new{ text = "Could not sign in to flush the queue." })
            return
        end
        local stats = self.sync:flushQueue(api)
        Notification:notify(
            string.format("Queue flush · %d sent · %d failed · %d left",
                stats.flushed, stats.failed, #self.cache:queuedActions()),
            Notification.SOURCE_ALWAYS_SHOW
        )
        if self.queue_menu then
            self:showQueueMenu()
        end
    end)
end

function Plugin:listedArticles()
    local browse = self:browseState()
    local mode = browse.mode or "unread"
    if mode == "feed" and not browse.feed_id then
        return {}
    end
    if mode == "label" and not browse.label then
        return {}
    end
    local list_mode = mode
    if mode == "feed" then list_mode = "feed" end
    if mode == "label" then list_mode = "label" end
    return self.cache:listByMode(list_mode, {
        feed_id = browse.feed_id,
        label = browse.label,
    })
end

function Plugin:articleIds()
    local ids = {}
    for _, article in ipairs(self:listedArticles()) do
        table.insert(ids, article.id)
    end
    return ids
end

function Plugin:buildItemTable()
    local browse = self:browseState()
    local entries = {}
    local mode = browse.mode or "unread"

    if mode == "feed" and not browse.feed_id then
        local meta = self.cache:getMeta()
        local subs = meta.subscriptions and meta.subscriptions.subscriptions or {}
        if #subs == 0 then
            table.insert(entries, {
                text = "No feeds cached · tap Refresh",
                select_enabled = false,
            })
        else
            for _, sub in ipairs(subs) do
                local sid = sub.id or sub.feedId
                local title = sub.title or sid or "Feed"
                table.insert(entries, {
                    text = title,
                    mandatory = sid,
                    callback = function()
                        self:setBrowseState({ mode = "feed", feed_id = sid })
                        self:showCached(true)
                        self:requestSync()
                    end,
                })
            end
        end
        return entries
    end

    if mode == "label" and not browse.label then
        local meta = self.cache:getMeta()
        local tags = meta.tags and meta.tags.tags or {}
        local labels = {}
        for _, tag in ipairs(tags) do
            local id = tag.id
            if type(id) == "string" and id:find("user/%-/label/", 1, false) then
                table.insert(labels, id)
            end
        end
        if #labels == 0 then
            table.insert(entries, {
                text = "No categories cached · tap Refresh",
                select_enabled = false,
            })
        else
            for _, label in ipairs(labels) do
                table.insert(entries, {
                    text = labelDisplayName(label),
                    callback = function()
                        self:setBrowseState({ mode = "label", label = label })
                        self:showCached(true)
                        self:requestSync()
                    end,
                })
            end
        end
        return entries
    end

    if mode == "feed" and browse.feed_id then
        table.insert(entries, {
            text = "← All feeds",
            callback = function()
                self:setBrowseState({ mode = "feed" })
                self:showCached(true)
            end,
        })
    elseif mode == "label" and browse.label then
        table.insert(entries, {
            text = "← All categories",
            callback = function()
                self:setBrowseState({ mode = "label" })
                self:showCached(true)
            end,
        })
    end

    local items = self:listedArticles()
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
    if #items == 0 then
        local offline = not NetworkMgr:isOnline()
        local empty_text = offline
            and "No cached articles · offline. Connect and tap Refresh."
            or "No cached articles. Tap Refresh to sync."
        table.insert(entries, { text = empty_text, select_enabled = false })
    end
    return entries
end

function Plugin:showBrowsePicker()
    local entries = {
        {
            text = "Unread",
            callback = function()
                self:setBrowseState({ mode = "unread" })
                UIManager:close(self.browse_picker)
                self.browse_picker = nil
                self:showCached(true)
            end,
        },
        {
            text = "All",
            callback = function()
                self:setBrowseState({ mode = "all" })
                UIManager:close(self.browse_picker)
                self.browse_picker = nil
                self:showCached(true)
            end,
        },
        {
            text = "Starred",
            callback = function()
                self:setBrowseState({ mode = "starred" })
                UIManager:close(self.browse_picker)
                self.browse_picker = nil
                self:showCached(true)
            end,
        },
        {
            text = "Feeds",
            callback = function()
                self:setBrowseState({ mode = "feed" })
                UIManager:close(self.browse_picker)
                self.browse_picker = nil
                self:showCached(true)
            end,
        },
        {
            text = "Categories",
            callback = function()
                self:setBrowseState({ mode = "label" })
                UIManager:close(self.browse_picker)
                self.browse_picker = nil
                self:showCached(true)
            end,
        },
    }
    if self.browse_picker then
        self.browse_picker:switchItemTable("Browse", entries)
        return
    end
    self.browse_picker = Menu:new{
        title = "Browse",
        item_table = entries,
        is_popout = false,
        is_borderless = true,
        covers_fullscreen = true,
        close_callback = function()
            self.browse_picker = nil
        end,
    }
    UIManager:show(self.browse_picker, "ui")
end

function Plugin:showSettingsMenu()
    local auto = self:autoRefreshEnabled()
    local unread_only = self:syncUnreadOnly()
    local pending = #self.cache:queuedActions()
    local entries = {
        {
            text = "Connection…",
            callback = function() self:showSetup() end,
        },
        {
            text = auto and "Auto-refresh on open: on" or "Auto-refresh on open: off",
            callback = function()
                self.settings:saveSetting("freshrss_auto_refresh", not auto)
                self.settings:flush()
                self:showSettingsMenu()
            end,
        },
        {
            text = unread_only and "Sync filter: unread only" or "Sync filter: all articles",
            callback = function()
                self.settings:saveSetting("freshrss_sync_unread_only", not unread_only)
                self.settings:flush()
                self:showSettingsMenu()
            end,
        },
        {
            text = "Articles per sync: " .. tostring(self:articlesPerSync()),
            callback = function()
                self:cycleArticlesPerSync()
                self:showSettingsMenu()
            end,
        },
        {
            text = string.format("Pending actions: %d", pending),
            callback = function() self:showQueueMenu() end,
        },
    }
    if self.settings_menu then
        self.settings_menu:switchItemTable("FreshRSS settings", entries)
        return
    end
    self.settings_menu = Menu:new{
        title = "FreshRSS settings",
        item_table = entries,
        is_popout = false,
        is_borderless = true,
        covers_fullscreen = true,
        close_callback = function()
            self.settings_menu = nil
            if self.home then self:showCached() end
        end,
    }
    UIManager:show(self.settings_menu, "ui")
end

function Plugin:showQueueMenu()
    local queue = self.cache:queuedActions()
    local entries = {
        {
            text = "Flush now",
            callback = function() self:flushQueueInteractive() end,
        },
        {
            text = "Clear queue",
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = "Clear all pending FreshRSS actions?",
                    ok_text = "Clear",
                    ok_callback = function()
                        local n = self.cache:clearQueue()
                        Notification:notify(string.format("Cleared %d queued actions", n), Notification.SOURCE_ALWAYS_SHOW)
                        self:showQueueMenu()
                    end,
                })
            end,
        },
    }
    if #queue == 0 then
        table.insert(entries, { text = "Queue is empty", select_enabled = false })
    else
        for _, action in ipairs(queue) do
            local state = action.state and "set" or "unset"
            table.insert(entries, {
                text = string.format("%s · %s · %s", tostring(action.action), state, tostring(action.id)),
                select_enabled = false,
            })
        end
    end
    if self.queue_menu then
        self.queue_menu:switchItemTable("Pending actions", entries)
        return
    end
    self.queue_menu = Menu:new{
        title = "Pending actions",
        item_table = entries,
        is_popout = false,
        is_borderless = true,
        covers_fullscreen = true,
        close_callback = function()
            self.queue_menu = nil
            if self.settings_menu then self:showSettingsMenu() end
        end,
    }
    UIManager:show(self.queue_menu)
end

function Plugin:confirmMarkAllRead()
    local browse = self:browseState()
    local label = MODE_LABELS[browse.mode] or "current view"
    if browse.mode == "feed" and browse.feed_id then
        label = "this feed"
    elseif browse.mode == "label" and browse.label then
        label = labelDisplayName(browse.label)
    elseif browse.mode == "feed" or browse.mode == "label" then
        UIManager:show(InfoMessage:new{ text = "Select a feed or category first." })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = "Mark all articles in " .. label .. " as read?",
        ok_text = "Mark read",
        ok_callback = function()
            local mode = browse.mode or "unread"
            local marked = self.cache:markAllRead(mode, {
                feed_id = browse.feed_id,
                label = browse.label,
            })
            local stream_id = self:currentStreamId()
            UIManager:nextTick(function()
                NetworkMgr:runWhenOnline(function()
                    self.sync:markAllAsRead(self:api(), stream_id)
                end)
            end)
            Notification:notify(string.format("Marked %d as read", marked), Notification.SOURCE_ALWAYS_SHOW)
            self:showCached()
        end,
    })
end

function Plugin:menuTitle()
    local browse = self:browseState()
    local mode = MODE_LABELS[browse.mode] or "FreshRSS"
    if browse.mode == "feed" and browse.feed_id then
        mode = "Feed"
    elseif browse.mode == "label" and browse.label then
        mode = labelDisplayName(browse.label)
    end
    return "FreshRSS  ·  " .. mode .. "  ·  " .. tostring(self.cache:unreadCount())
end

function Plugin:menuSubtitle()
    local last = self.settings:readSetting("freshrss_last_sync") or self.settings:readSetting("last_sync")
    local filter = self:syncUnreadOnly() and "sync:unread" or "sync:all"
    local cap = self:articlesPerSync()
    local pending = #self.cache:queuedActions()
    local pending_bit = pending > 0 and string.format(" · queue %d", pending) or ""
    if not last then
        return string.format("Not synced yet · %s · cap %d%s", filter, cap, pending_bit)
    end
    return string.format("Last sync · %s · %s · cap %d%s",
        os.date("%Y-%m-%d %H:%M", tonumber(last) or os.time()), filter, cap, pending_bit)
end

function Plugin:onHomeClosed()
    Status:close()
    self.home = nil
    self.menu = nil
end

function Plugin:showCached(rebuild_chrome)
    if self.home and not rebuild_chrome then
        if self.home.title_bar then
            self.home.title_bar:setTitle(self:menuTitle())
            self.home.title_bar:setSubTitle(self:menuSubtitle())
        end
        self.home:updateList()
        return
    end
    if self.home then
        UIManager:close(self.home)
        self.home = nil
        self.menu = nil
    end
    self.home = Home:new{ plugin = self }
    self.menu = self.home.list
    UIManager:show(self.home, "ui")
end

function Plugin:refreshHomeAfterViewer()
    if not self.home then return end
    if self.home.title_bar then
        self.home.title_bar:setTitle(self:menuTitle())
        self.home.title_bar:setSubTitle(self:menuSubtitle())
    end
    self.home:updateList()
    UIManager:setDirty(self.home, "ui")
end

function Plugin:loadViewerImages(article, viewer)
    if not viewer or not viewer.show_images then return end
    local raw = tostring(article and article.html or "")
    local urls = Images.extractImageUrls(raw)
    if #urls == 0 then return end
    local data_dir = self.cache.root
    local cached_map = select(1, Images.cachedMap(raw, data_dir))
    local need_download = false
    for _, url in ipairs(urls) do
        if not cached_map[url] then
            need_download = true
            break
        end
    end
    if not need_download then
        if next(cached_map) then
            viewer:applyImageMap(cached_map, Images.directory(data_dir))
        end
        return
    end
    if not NetworkMgr:isOnline() then
        if next(cached_map) then
            viewer:applyImageMap(cached_map, Images.directory(data_dir))
        end
        return
    end
    Status:show("Loading images…", 0.2)
    local map, dir, downloaded = Images.prepare(raw, {
        data_dir = data_dir,
        download = true,
        is_online = true,
    })
    Status:close()
    if viewer ~= self.viewer then return end
    if downloaded > 0 or next(map) then
        viewer:applyImageMap(map, dir)
    end
end

function Plugin:openArticle(id)
    local article = self.cache:getArticle(id)
    if not article then return end
    local ids = self:articleIds()
    local index = 1
    for i, aid in ipairs(ids) do
        if tostring(aid) == tostring(id) then
            index = i
            break
        end
    end
    local prev_id = ids[index - 1]
    local next_id = ids[index + 1]

    article.unread = false
    self.cache:putArticle(article)

    local function reopen(neighbor_id)
        if self.viewer then
            UIManager:close(self.viewer)
            self.viewer = nil
        end
        self:openArticle(neighbor_id)
    end

    local data_dir = self.cache.root
    local show_images = Renderer.readShowImages()
    local image_map, resource_dir = {}, nil
    if show_images then
        image_map, resource_dir = Images.cachedMap(article.html or "", data_dir)
    end

    local widget
    widget = Renderer:articleWidget(article, {
        index = index,
        total = #ids,
        prev_id = prev_id,
        next_id = next_id,
        data_dir = data_dir,
        image_map = image_map,
        html_resource_directory = resource_dir,
        on_back = function()
            -- Viewer X / Back: only clear viewer and refresh list — never rebuild/close Home.
            self.viewer = nil
            self:refreshHomeAfterViewer()
        end,
        on_prev = function()
            if prev_id then reopen(prev_id) end
        end,
        on_next = function()
            if next_id then reopen(next_id) end
        end,
        on_unread = function()
            article.unread = true
            self.cache:putArticle(article)
            UIManager:nextTick(function()
                local ok = self.sync:applyAction(self:api(), id, "read", false)
                if ok then
                    Notification:notify("Marked unread · synced", Notification.SOURCE_ALWAYS_SHOW)
                else
                    Notification:notify("Marked unread · queued offline", Notification.SOURCE_ALWAYS_SHOW)
                end
            end)
        end,
        on_star = function()
            article.starred = not article.starred
            self.cache:putArticle(article)
            if self.viewer and self.viewer.refreshActionButtons then
                self.viewer.article = article
                self.viewer:refreshActionButtons()
            end
            local starred = article.starred
            local verb = starred and "Favorited" or "Unfavorited"
            UIManager:nextTick(function()
                local ok = self.sync:applyAction(self:api(), id, "starred", starred)
                if ok then
                    Notification:notify(verb .. " · synced", Notification.SOURCE_ALWAYS_SHOW)
                else
                    Notification:notify(verb .. " · queued offline", Notification.SOURCE_ALWAYS_SHOW)
                end
            end)
        end,
        on_images_enabled = function()
            if widget then
                UIManager:nextTick(function()
                    self:loadViewerImages(article, widget)
                end)
            end
        end,
        on_link = function(href)
            UIManager:show(ConfirmBox:new{
                text = "Open link?\n" .. tostring(href),
                ok_text = "Open",
                ok_callback = function()
                    if Device.openLink then
                        Device:openLink(href)
                    else
                        UIManager:show(InfoMessage:new{ text = tostring(href) })
                    end
                end,
            })
        end,
    })
    self.viewer = widget
    UIManager:show(widget, "ui")
    -- Viewer first, then download any missing images and rebuild once.
    UIManager:nextTick(function()
        self.sync:applyAction(self:api(), id, "read", true)
        self:loadViewerImages(article, widget)
    end)
end

return Plugin
