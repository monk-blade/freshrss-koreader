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
local SpinWidget = require("ui/widget/spinwidget")
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
local Nav = dofile(plugin_dir .. "/nav.lua")
local ListFonts = dofile(plugin_dir .. "/list_fonts.lua")
local ListFormat = dofile(plugin_dir .. "/list_format.lua")
local FavCategories = dofile(plugin_dir .. "/fav_categories.lua")
local SettingsUI = dofile(plugin_dir .. "/settings_ui.lua")

local Plugin = WidgetContainer:extend{
    name = "freshrss",
    is_doc_only = false,
}

-- Seconds after forceRePaint before deferred open stages.
-- Image work must NOT run in nextTick: Images.prepare / MuPDF reinit can stall UI.
-- Mark-read on open is local cache + action queue only (no HTTP until Sync).
Plugin.ARTICLE_OPEN_DEFER_CACHED_IMAGES = 0.25
Plugin.ARTICLE_OPEN_DEFER_DOWNLOAD = 0.75
Plugin.ARTICLE_OPEN_DEFER_IMAGES_RETRY = 1.0

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
    self.sync.images = Images
    self.icons = Icons:new(plugin_dir)
    self.icons:install()
    Status:setIcons(self.icons)
    self.list_fonts = ListFonts
    self.api_client = nil
    self.home = nil
    self.menu = nil -- alias to home.list when home is open
    self.settings_menu = nil
    self.queue_menu = nil
    self.list_font_menu = nil
    self.browse_picker = nil
    self.viewer = nil
    self.syncing = false
    self._list_restore = nil -- { page = n, article_id = id }
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

function Plugin:markReadOnOpen()
    local value = self.settings:readSetting("freshrss_mark_read_on_open")
    if value == nil then return true end
    return value and true or false
end

-- Cancel deferred openArticle stages (cached images / download / sync-retry).
-- Must run before a new open, on viewer close/detach, and Prev/Next reopen.
function Plugin:cancelArticleOpenTasks()
    local tasks = self._article_open_tasks
    if not tasks then return end
    for i = #tasks, 1, -1 do
        local action = tasks[i]
        tasks[i] = nil
        if action then
            pcall(function() UIManager:unschedule(action) end)
        end
    end
    self._article_open_tasks = nil
end

function Plugin:_scheduleArticleOpenTask(seconds, action)
    if type(action) ~= "function" then return end
    local tasks = self._article_open_tasks
    if not tasks then
        tasks = {}
        self._article_open_tasks = tasks
    end
    table.insert(tasks, action)
    UIManager:scheduleIn(seconds, action)
    return action
end

function Plugin:cleanCacheNow()
    local retain = Cache.readMaxRetained(self.settings)
    local evicted = self.cache:evictOldest(retain)
    local keep = Images.referencedFilenames(self.cache)
    local purged = Images.purgeOrphans(self.cache.root, keep)
    Notification:notify(
        string.format("Cache clean · %d articles removed · %d images purged", evicted, purged),
        Notification.SOURCE_ALWAYS_SHOW
    )
    if self.home then self:showCached() end
    return evicted, purged
end

function Plugin:articlesPerSync()
    return Sync.readArticleCap(self.settings)
end

function Plugin:showSyncLimitSpin()
    UIManager:show(SpinWidget:new{
        title_text = "Sync limit",
        info_text = "Max articles to sync for the active view",
        value = self:articlesPerSync(),
        value_min = Sync.MIN_ARTICLE_CAP,
        value_max = Sync.MAX_ARTICLE_CAP,
        default_value = Sync.DEFAULT_ARTICLE_CAP,
        ok_always_enabled = true,
        keep_shown_on_apply = true,
        callback = function(spin)
            Sync.saveArticleCap(self.settings, spin.value)
            self:showSyncSettings()
        end,
    })
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
    self._list_restore = nil
end

function Plugin:currentStreamId()
    return self.sync:resolveStreamId(self:browseState())
end

function Plugin:syncScopeLabel()
    return Sync.readSyncScope(self.settings) == Sync.SCOPE_READING_LIST
        and "Sync scope: reading list"
        or "Sync scope: current view"
end

function Plugin:rememberListPosition()
    local list = self.home and self.home.list
    if not list then return end
    self._list_restore = {
        page = tonumber(list.page) or 1,
        article_id = nil,
    }
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
    return function(stage, ratio, detail)
        local label = Sync.formatProgressLabel(stage, detail)
        Status:update(label, ratio)
    end
end

function Plugin:cancelSync()
    if self.syncing and self.sync then
        self.sync:requestCancel()
        Status:update("Cancelling…", nil)
    end
end

function Plugin:startSync(interactive)
    if self.syncing then return end
    self.syncing = true
    local browse = self:browseState()
    local stream_id = self.sync:resolveStreamId(browse)
    local stream_label = Sync.streamLabel(browse, stream_id, self.cache)
    Status:show("Sync · " .. stream_label, 0.05, function()
        self:cancelSync()
    end)

    local function done(ok, result)
        self.syncing = false
        Status:close()
        if result and result.cancelled then
            local fetched = result.fetched or 0
            Notification:notify(
                string.format("Sync cancelled · %d fetched", fetched),
                Notification.SOURCE_ALWAYS_SHOW
            )
            if self.home then
                self:showCached()
            end
            return
        end
        if not ok then
            if interactive then
                UIManager:show(InfoMessage:new{ text = "FreshRSS unavailable:\n" .. tostring(result) })
            else
                Notification:notify("FreshRSS sync failed", Notification.SOURCE_ALWAYS_SHOW)
            end
            return
        end
        local browse = self:browseState()
        local unread = self.cache:unreadCountForBrowse(browse)
        local fetched = result and result.fetched or 0
        local ids_seen = result and result.ids_seen or 0
        local ids_skipped = result and result.ids_skipped or 0
        local mode = (result and result.exclude_read) and "unread" or "all"
        local flushed = result and result.flushed or 0
        local failed = result and result.flush_failed or 0
        local label = result and result.stream_label or stream_label
        local msg
        if ids_seen > 0 and ids_skipped > 0 then
            msg = string.format("%s · %d fetched · %d skipped / %d ids · %d unread",
                label, fetched, ids_skipped, ids_seen, unread)
        elseif ids_seen > 0 then
            msg = string.format("%s · %d fetched / %d ids · %d unread",
                label, fetched, ids_seen, unread)
        else
            msg = string.format("%s · %d fetched (%s) · %d unread", label, fetched, mode, unread)
        end
        if flushed > 0 or failed > 0 then
            msg = msg .. string.format(" · queue %d ok / %d failed", flushed, failed)
        end
        local evicted = result and result.evicted or 0
        if evicted > 0 then
            msg = msg .. string.format(" · evicted %d", evicted)
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
        sort = Cache.readListSort(self.settings),
        hidden_feeds = Cache.readHiddenFeeds(self.settings),
        apply_hidden = (mode == "all" or mode == "unread"),
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
                text = "No feeds cached · tap the FreshRSS icon to sync",
                select_enabled = false,
            })
        else
            for _, sub in ipairs(subs) do
                local sid = sub.id or sub.feedId
                local title = sub.title or sid or "Feed"
                local hidden = Cache.isFeedHidden(self.settings, sid)
                if hidden then
                    title = title .. " · Hidden"
                end
                local count = self.cache:unreadCountForStream(sid)
                local mandatory
                if count ~= nil then
                    mandatory = tostring(count)
                end
                table.insert(entries, {
                    text = title,
                    mandatory = mandatory,
                    callback = function()
                        self:setBrowseState({ mode = "feed", feed_id = sid })
                        self:showCached(true)
                        -- Do not auto-sync on feed open — user taps FreshRSS icon to sync.
                    end,
                    hold_callback = function()
                        local now_hidden = Cache.toggleHiddenFeed(self.settings, sid)
                        Notification:notify(
                            now_hidden and "Feed hidden from All/Unread" or "Feed shown in All/Unread",
                            Notification.SOURCE_ALWAYS_SHOW
                        )
                        self:showCached(true)
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
                text = "No categories cached · tap the FreshRSS icon to sync",
                select_enabled = false,
            })
        else
            for _, label in ipairs(labels) do
                local count = self.cache:unreadCountForStream(label)
                local mandatory
                if count ~= nil then
                    mandatory = tostring(count)
                end
                table.insert(entries, {
                    text = labelDisplayName(label),
                    mandatory = mandatory,
                    callback = function()
                        self:setBrowseState({ mode = "label", label = label })
                        self:showCached(true)
                        -- Do not auto-sync on category open — user taps FreshRSS icon to sync.
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
    -- Dense e-ink glyphs: filled bullet = unread, hollow = read, star = favorite.
    -- Line 1: markers + title; line 2: feed · time (ListMenuItem subtitle).
    for _, article in ipairs(items) do
        table.insert(entries, {
            text = ListFormat.rowTitle(article, { title = articleTitle(article) }),
            subtitle = ListFormat.rowMandatory(article),
            article_id = article.id,
            callback = function() self:openArticle(article.id) end,
        })
    end
    if #items == 0 then
        local offline = not NetworkMgr:isOnline()
        local empty_text = offline
            and "No cached articles · offline. Connect and tap the FreshRSS icon."
            or "No cached articles. Tap the FreshRSS icon to sync."
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
        is_enable_shortcut = false,
        close_callback = function()
            self.browse_picker = nil
        end,
    }
    UIManager:show(self.browse_picker, "ui")
end

function Plugin:listFontLabel()
    local path = ListFonts.readLatinFont()
    if path then
        return "List font: " .. ListFonts.displayName(path)
    end
    return "List font: Default"
end

function Plugin:showViewerFontPicker()
    local FontList = require("fontlist")
    local fonts = FontList:getFontList() or {}
    local current = ListFonts.readViewerFont()
    local entries = {
        {
            text = "Default" .. (not current and " ✓" or ""),
            callback = function()
                ListFonts.saveViewerFont(nil)
                UIManager:close(self.viewer_font_menu)
                self.viewer_font_menu = nil
                if self.appearance_menu then
                    self:showAppearanceSettings()
                elseif self.settings_menu then
                    self:showSettingsMenu()
                end
                if self.viewer and self.viewer.reinit then
                    self.viewer.font_face = nil
                    self.viewer:reinit()
                end
            end,
        },
    }
    for _, path in ipairs(fonts) do
        local name = path:match("([^/]+)$") or path
        local selected = current == path and " ✓" or ""
        table.insert(entries, {
            text = name .. selected,
            callback = function()
                ListFonts.saveViewerFont(path)
                UIManager:close(self.viewer_font_menu)
                self.viewer_font_menu = nil
                if self.appearance_menu then
                    self:showAppearanceSettings()
                elseif self.settings_menu then
                    self:showSettingsMenu()
                end
                if self.viewer and self.viewer.reinit then
                    self.viewer.font_face = path
                    self.viewer:reinit()
                end
            end,
        })
    end
    if self.viewer_font_menu then
        UIManager:close(self.viewer_font_menu)
    end
    self.viewer_font_menu = Menu:new{
        title = "Viewer font",
        item_table = entries,
        is_popout = false,
        is_borderless = true,
        covers_fullscreen = true,
        is_enable_shortcut = false,
        close_callback = function()
            self.viewer_font_menu = nil
            if self.appearance_menu then
                self:showAppearanceSettings()
            elseif self.settings_menu then
                self:showSettingsMenu()
            end
        end,
    }
    UIManager:show(self.viewer_font_menu, "ui")
end

function Plugin:showListFontPicker()
    local FontList = require("fontlist")
    local fonts = FontList:getFontList() or {}
    local current = ListFonts.readLatinFont()
    local entries = {
        {
            text = "Default" .. (not current and " ✓" or ""),
            callback = function()
                ListFonts.saveLatinFont(nil)
                UIManager:close(self.list_font_menu)
                self.list_font_menu = nil
                ListFonts.apply()
                if self.home then self.home:updateList() end
                if self.appearance_menu then
                    self:showAppearanceSettings()
                else
                    self:showSettingsMenu()
                end
            end,
        },
    }
    for _, path in ipairs(fonts) do
        local name = path:match("([^/]+)$") or path
        local selected = current == path and " ✓" or ""
        table.insert(entries, {
            text = name .. selected,
            callback = function()
                ListFonts.saveLatinFont(path)
                UIManager:close(self.list_font_menu)
                self.list_font_menu = nil
                ListFonts.apply()
                if self.home then self.home:updateList() end
                if self.appearance_menu then
                    self:showAppearanceSettings()
                else
                    self:showSettingsMenu()
                end
            end,
        })
    end
    if self.list_font_menu then
        UIManager:close(self.list_font_menu)
    end
    self.list_font_menu = Menu:new{
        title = "List font",
        item_table = entries,
        is_popout = false,
        is_borderless = true,
        covers_fullscreen = true,
        is_enable_shortcut = false,
        close_callback = function()
            self.list_font_menu = nil
            if self.appearance_menu then
                self:showAppearanceSettings()
            elseif self.settings_menu then
                self:showSettingsMenu()
            end
        end,
    }
    UIManager:show(self.list_font_menu, "ui")
end

function Plugin:closeSettingsSubmenu(menu_key)
    if menu_key and self[menu_key] then
        UIManager:close(self[menu_key])
        self[menu_key] = nil
    end
    self:showSettingsMenu()
end

---Convert legacy {text, callback} Menu rows into SettingsUI icon rows.
function Plugin:settingsRowsFromEntries(entries, default_icon)
    local rows = {}
    for _, entry in ipairs(entries or {}) do
        if entry.select_enabled == false and not entry.callback then
            table.insert(rows, {
                icon = self.icons:name(entry.icon or default_icon or "circle"),
                text = entry.text,
                callback = function() end,
            })
        else
            table.insert(rows, {
                icon = self.icons:name(entry.icon or default_icon or "settings"),
                text = entry.text,
                callback = entry.callback,
                hold_callback = entry.hold_callback,
            })
        end
    end
    return rows
end

function Plugin:showSettingsSubmenu(menu_key, title, entries, default_icon)
    if self[menu_key] then
        UIManager:close(self[menu_key])
        self[menu_key] = nil
    end
    local panel
    panel = SettingsUI.showPanel({
        title = title,
        icons = self.icons,
        rows = self:settingsRowsFromEntries(entries, default_icon),
        on_close = function()
            if self[menu_key] == panel then self[menu_key] = nil end
            self:showSettingsMenu()
        end,
    })
    self[menu_key] = panel
end

function Plugin:showFavoriteCategoryPicker()
    local labels = FavCategories.availableLabels(self.cache)
    local rows = {}
    if #labels == 0 then
        table.insert(rows, {
            icon = self.icons:name("inbox"),
            text = "No categories cached · sync first",
            callback = function() end,
        })
    else
        for _, id in ipairs(labels) do
            local name = FavCategories.labelDisplayName(id)
            local fav = FavCategories.isFavorite(self.settings, id)
            table.insert(rows, {
                icon = self.icons:name(fav and "star_filled" or "star"),
                text = (fav and "★ " or "") .. name,
                callback = function()
                    if fav then
                        FavCategories.remove(self.settings, id)
                        Notification:notify("Removed favorite category", Notification.SOURCE_ALWAYS_SHOW)
                    else
                        FavCategories.add(self.settings, id)
                        Notification:notify("Added favorite category", Notification.SOURCE_ALWAYS_SHOW)
                    end
                    if self.fav_cat_panel then
                        UIManager:close(self.fav_cat_panel)
                        self.fav_cat_panel = nil
                    end
                    if self.home then
                        self:showCached(true)
                    end
                end,
                hold_callback = function()
                    if not FavCategories.isFavorite(self.settings, id) then
                        FavCategories.add(self.settings, id)
                    end
                    self:showCategoryIconPicker(id)
                end,
            })
        end
    end
    if self.fav_cat_panel then
        UIManager:close(self.fav_cat_panel)
        self.fav_cat_panel = nil
    end
    self.fav_cat_panel = SettingsUI.showPanel({
        title = "Favorite categories",
        icons = self.icons,
        rows = rows,
        on_close = function()
            self.fav_cat_panel = nil
            if self.home then self:showCached(true) end
        end,
    })
end

function Plugin:showCategoryIconPicker(label_id)
    label_id = tostring(label_id or "")
    if label_id == "" then return end
    local name = FavCategories.labelDisplayName(label_id)
    local rows = {
        {
            icon = nil,
            letters = FavCategories.twoLetters(name),
            text = "Letters (default)",
            callback = function()
                FavCategories.setIcon(self.settings, label_id, nil)
                if self.cat_icon_panel then
                    UIManager:close(self.cat_icon_panel)
                    self.cat_icon_panel = nil
                end
                if self.home then self:showCached(true) end
            end,
        },
    }
    for _, key in ipairs(FavCategories.ICON_PALETTE) do
        if self.icons:has(key) then
            local icon_key = key
            table.insert(rows, {
                icon = self.icons:name(icon_key),
                text = icon_key:gsub("_", " "),
                callback = function()
                    FavCategories.setIcon(self.settings, label_id, icon_key)
                    if self.cat_icon_panel then
                        UIManager:close(self.cat_icon_panel)
                        self.cat_icon_panel = nil
                    end
                    if self.home then self:showCached(true) end
                end,
            })
        end
    end
    if self.cat_icon_panel then
        UIManager:close(self.cat_icon_panel)
        self.cat_icon_panel = nil
    end
    self.cat_icon_panel = SettingsUI.showPaginatedPanel({
        title = "Icon · " .. name,
        icons = self.icons,
        rows = rows,
        set_panel = function(panel)
            self.cat_icon_panel = panel
        end,
        on_close = function()
            self.cat_icon_panel = nil
        end,
    })
end

function Plugin:showConnectionSettings()
    local auto = self:autoRefreshEnabled()
    local mark_on_open = self:markReadOnOpen()
    self:showSettingsSubmenu("connection_menu", "Connection", {
        {
            icon = "plug",
            text = "API connection…",
            callback = function() self:showSetup() end,
        },
        {
            icon = "refresh",
            text = auto and "Auto-refresh on open: on" or "Auto-refresh on open: off",
            callback = function()
                self.settings:saveSetting("freshrss_auto_refresh", not auto)
                self.settings:flush()
                self:showConnectionSettings()
            end,
        },
        {
            icon = "check_circle",
            text = mark_on_open and "Mark read on open: on" or "Mark read on open: off",
            callback = function()
                self.settings:saveSetting("freshrss_mark_read_on_open", not mark_on_open)
                self.settings:flush()
                self:showConnectionSettings()
            end,
        },
    }, "plug")
end

function Plugin:showSyncSettings()
    local unread_only = self:syncUnreadOnly()
    local sort = Cache.readListSort(self.settings)
    self:showSettingsSubmenu("sync_menu", "Sync", {
        {
            icon = "list_filter",
            text = unread_only and "Sync filter: unread only" or "Sync filter: all articles",
            callback = function()
                self.settings:saveSetting("freshrss_sync_unread_only", not unread_only)
                self.settings:flush()
                self:showSyncSettings()
            end,
        },
        {
            icon = "refresh",
            text = self:syncScopeLabel(),
            callback = function()
                Sync.cycleSyncScope(self.settings)
                self:showSyncSettings()
            end,
        },
        {
            icon = "inbox",
            text = "Sync limit: " .. tostring(self:articlesPerSync()),
            callback = function() self:showSyncLimitSpin() end,
        },
        {
            icon = "move_vertical",
            text = sort == Cache.SORT_OLDEST and "List sort: oldest first" or "List sort: newest first",
            callback = function()
                Cache.cycleListSort(self.settings)
                if self.home then self.home:updateList() end
                self:showSyncSettings()
            end,
        },
    }, "refresh")
end

function Plugin:showCacheSettings()
    local cache_size = Cache.formatSize(self.cache:approxSizeBytes())
    self:showSettingsSubmenu("cache_menu", "Cache", {
        {
            icon = "database",
            text = "Cache retain articles: " .. tostring(Cache.readMaxRetained(self.settings)),
            callback = function()
                Cache.cycleMaxRetained(self.settings)
                self:showCacheSettings()
            end,
        },
        {
            icon = "database",
            text = "Cache size ≈ " .. cache_size,
            select_enabled = false,
        },
        {
            icon = "database",
            text = "Clean cache now…",
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = "Remove oldest non-starred articles beyond the retain cap and purge orphan images?",
                    ok_text = "Clean",
                    ok_callback = function()
                        self:cleanCacheNow()
                        self:showCacheSettings()
                    end,
                })
            end,
        },
    }, "database")
end

function Plugin:showAppearanceSettings()
    -- FontList scan only when Appearance opens (not on every article open).
    local ok_fl, FontList = pcall(require, "fontlist")
    local font_list = (ok_fl and FontList and FontList:getFontList()) or {}
    ListFonts.maybeShowMissingHint(function(msg)
        UIManager:show(InfoMessage:new{ text = msg, timeout = 6 })
    end, font_list)
    self:showSettingsSubmenu("appearance_menu", "Appearance", {
        {
            icon = "type",
            text = self:listFontLabel(),
            callback = function() self:showListFontPicker() end,
        },
        {
            icon = "a_large_small",
            text = "List font size: " .. tostring(ListFonts.readFontSize()),
            callback = function()
                UIManager:show(SpinWidget:new{
                    title_text = "List font size",
                    value = ListFonts.readFontSize(),
                    value_min = ListFonts.SIZE_MIN,
                    value_max = ListFonts.SIZE_MAX,
                    default_value = ListFonts.DEFAULT_SIZE,
                    ok_always_enabled = true,
                    keep_shown_on_apply = true,
                    callback = function(spin)
                        ListFonts.saveFontSize(spin.value)
                        if self.home then self.home:updateList() end
                        self:showAppearanceSettings()
                    end,
                })
            end,
        },
        {
            icon = "star",
            text = "Favorite categories…",
            callback = function() self:showFavoriteCategoryPicker() end,
        },
        {
            icon = "type",
            text = ListFonts.viewerFontLabel(),
            callback = function() self:showViewerFontPicker() end,
        },
        {
            icon = "a_large_small",
            text = "Viewer font size: " .. tostring(Renderer.readFontSize()),
            callback = function()
                UIManager:show(SpinWidget:new{
                    title_text = "Font size",
                    value = Renderer.readFontSize(),
                    value_min = Renderer.FONT_SIZE_MIN,
                    value_max = Renderer.FONT_SIZE_MAX,
                    default_value = Renderer.DEFAULT_FONT_SIZE,
                    ok_always_enabled = true,
                    keep_shown_on_apply = true,
                    callback = function(spin)
                        Renderer.saveFontSize(spin.value)
                        self:showAppearanceSettings()
                    end,
                })
            end,
        },
        {
            icon = "heading",
            text = "Title font size: " .. tostring(Renderer.readTitleFontSize()),
            callback = function()
                UIManager:show(SpinWidget:new{
                    title_text = "Title font size",
                    value = Renderer.readTitleFontSize(),
                    value_min = Renderer.FONT_SIZE_MIN,
                    value_max = Renderer.FONT_SIZE_MAX,
                    default_value = Renderer.DEFAULT_TITLE_FONT_SIZE,
                    ok_always_enabled = true,
                    keep_shown_on_apply = true,
                    callback = function(spin)
                        Renderer.saveTitleFontSize(spin.value)
                        self:showAppearanceSettings()
                    end,
                })
            end,
        },
        {
            icon = "move_vertical",
            text = "Viewer line height: " .. Renderer.formatLineHeight(Renderer.readLineHeight()),
            callback = function()
                Renderer.showSpacingSpin({
                    title = "Line height",
                    info_text = "Article body line spacing",
                    value = Renderer.readLineHeight(),
                    value_min = Renderer.LINE_HEIGHT_MIN,
                    value_max = Renderer.LINE_HEIGHT_MAX,
                    value_step = Renderer.LINE_HEIGHT_STEP,
                    precision = "%.2f",
                    default_value = Renderer.DEFAULT_LINE_HEIGHT,
                    callback = function(value)
                        Renderer.saveLineHeight(value)
                        self:showAppearanceSettings()
                    end,
                })
            end,
        },
        {
            icon = "square",
            text = "Viewer side padding: " .. Renderer.formatPad(Renderer.readPadSide()),
            callback = function()
                Renderer.showSpacingSpin({
                    title = "Side padding",
                    info_text = "Left and right body padding (em)",
                    value = Renderer.readPadSide(),
                    value_min = Renderer.PAD_MIN,
                    value_max = Renderer.PAD_MAX,
                    value_step = Renderer.PAD_STEP,
                    precision = "%.1f",
                    default_value = Renderer.DEFAULT_PAD_SIDE,
                    callback = function(value)
                        Renderer.savePadSide(value)
                        self:showAppearanceSettings()
                    end,
                })
            end,
        },
        {
            icon = "panel_left",
            text = "Viewer top margin: " .. Renderer.formatPad(Renderer.readPadTop()),
            callback = function()
                Renderer.showSpacingSpin({
                    title = "Top margin",
                    info_text = "Top body padding (em)",
                    value = Renderer.readPadTop(),
                    value_min = Renderer.PAD_MIN,
                    value_max = Renderer.PAD_MAX,
                    value_step = Renderer.PAD_STEP,
                    precision = "%.1f",
                    default_value = Renderer.DEFAULT_PAD_TOP,
                    callback = function(value)
                        Renderer.savePadTop(value)
                        self:showAppearanceSettings()
                    end,
                })
            end,
        },
        {
            icon = "panel_left",
            text = "Viewer bottom margin: " .. Renderer.formatPad(Renderer.readPadBottom()),
            callback = function()
                Renderer.showSpacingSpin({
                    title = "Bottom margin",
                    info_text = "Bottom body padding (em)",
                    value = Renderer.readPadBottom(),
                    value_min = Renderer.PAD_MIN,
                    value_max = Renderer.PAD_MAX,
                    value_step = Renderer.PAD_STEP,
                    precision = "%.1f",
                    default_value = Renderer.DEFAULT_PAD_BOTTOM,
                    callback = function(value)
                        Renderer.savePadBottom(value)
                        self:showAppearanceSettings()
                    end,
                })
            end,
        },
    }, "type")
end

function Plugin:showImageSettings()
    self:showSettingsSubmenu("images_menu", "Images", {
        {
            icon = "image",
            text = "Images per article: " .. tostring(Images.readMaxImages()),
            callback = function()
                Images.cycleMaxImages()
                self:showImageSettings()
            end,
        },
        {
            icon = "image",
            text = "Sync image budget: " .. tostring(Images.readSyncBudget()),
            callback = function()
                Images.cycleSyncBudget()
                self:showImageSettings()
            end,
        },
        {
            icon = "image",
            text = "Image download parallel: " .. tostring(Images.readMaxParallel()),
            callback = function()
                Images.cycleMaxParallel()
                self:showImageSettings()
            end,
        },
        {
            icon = "image",
            text = "Image max size: " .. Images.formatMaxBytesLabel(Images.readMaxBytes()),
            callback = function()
                Images.cycleMaxBytes()
                self:showImageSettings()
            end,
        },
        {
            icon = "image",
            text = "Image timeouts: " .. Images.readTimeoutProfile(),
            callback = function()
                Images.cycleTimeoutProfile()
                self:showImageSettings()
            end,
        },
    }, "image")
end

function Plugin:showSettingsMenu()
    local pending = #self.cache:queuedActions()
    local rows = {
        {
            icon = self.icons:name("plug"),
            text = "Connection…",
            callback = function() self:showConnectionSettings() end,
        },
        {
            icon = self.icons:name("refresh"),
            text = "Sync…",
            callback = function() self:showSyncSettings() end,
        },
        {
            icon = self.icons:name("database"),
            text = "Cache…",
            callback = function() self:showCacheSettings() end,
        },
        {
            icon = self.icons:name("type"),
            text = "Appearance…",
            callback = function() self:showAppearanceSettings() end,
        },
        {
            icon = self.icons:name("image"),
            text = "Images…",
            callback = function() self:showImageSettings() end,
        },
        {
            icon = self.icons:name("inbox"),
            text = string.format("Queue… (%d pending)", pending),
            callback = function() self:showQueueMenu() end,
        },
        {
            icon = self.icons:name("check_circle"),
            text = "Mark all as read…",
            callback = function() self:confirmMarkAllRead() end,
        },
    }
    if self.settings_menu then
        UIManager:close(self.settings_menu)
        self.settings_menu = nil
    end
    self.settings_menu = SettingsUI.showPanel({
        title = "FreshRSS settings",
        icons = self.icons,
        rows = rows,
        on_close = function()
            self.settings_menu = nil
            self.connection_menu = nil
            self.sync_menu = nil
            self.cache_menu = nil
            self.appearance_menu = nil
            self.images_menu = nil
            if self.home then
                ListFonts.apply()
                self:showCached()
            end
        end,
    })
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
            local verb = tostring(action.action or "?")
            if verb == "read" then
                verb = action.state and "Mark read" or "Mark unread"
            elseif verb == "starred" then
                verb = action.state and "Favorite" or "Unfavorite"
            end
            local title
            local art = self.cache:getArticle(action.id)
            if art and art.title then
                title = util.htmlEntitiesToUtf8(tostring(art.title))
                if #title > 40 then title = title:sub(1, 37) .. "…" end
            else
                local id = tostring(action.id or "")
                title = #id > 24 and (id:sub(1, 21) .. "…") or id
            end
            table.insert(entries, {
                text = string.format("%s · %s", verb, title),
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
        is_enable_shortcut = false,
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
    -- Single line: mode · unread (for this view) · last sync (subtitle unused).
    local browse = self:browseState()
    local mode = MODE_LABELS[browse.mode] or "FreshRSS"
    if browse.mode == "feed" and browse.feed_id then
        mode = "Feed"
        local meta = self.cache:getMeta()
        local subs = meta.subscriptions and meta.subscriptions.subscriptions or {}
        for _, sub in ipairs(subs) do
            local sid = sub.id or sub.feedId
            if sid == browse.feed_id then
                mode = sub.title or sid or "Feed"
                break
            end
        end
    elseif browse.mode == "label" and browse.label then
        mode = labelDisplayName(browse.label)
    end
    local count = tostring(self.cache:unreadCountForBrowse(browse))
    local sync = self:menuSubtitle()
    if sync and sync ~= "" then
        return mode .. "  ·  " .. count .. "  ·  " .. sync
    end
    return mode .. "  ·  " .. count
end

function Plugin:menuSubtitle()
    -- Kept for callers; primary chrome merges this into menuTitle().
    local last = self.settings:readSetting("freshrss_last_sync") or self.settings:readSetting("last_sync")
    local pending = #self.cache:queuedActions()
    local pending_bit = pending > 0 and string.format(" · queue %d", pending) or ""
    if not last then
        return "Not synced" .. pending_bit
    end
    local ts = tonumber(last) or os.time()
    local today = os.date("%Y-%m-%d")
    local sync_day = os.date("%Y-%m-%d", ts)
    if sync_day == today then
        return os.date("%H:%M", ts) .. pending_bit
    end
    return os.date("%Y-%m-%d %H:%M", ts) .. pending_bit
end

function Plugin:closeHomeOverlays()
    local keys = {
        "browse_picker",
        "list_font_menu",
        "viewer_font_menu",
        "settings_menu",
        "fav_cat_panel",
        "cat_icon_panel",
    }
    for _, key in ipairs(keys) do
        local widget = self[key]
        if widget then
            pcall(function() UIManager:close(widget) end)
            self[key] = nil
        end
    end
end

function Plugin:onHomeClosed()
    Status:close()
    self.home = nil
    self.menu = nil
    self._list_restore = nil
end

function Plugin:showCached(rebuild_chrome)
    if self.icons then
        self.icons:install()
    end
    if self.list_fonts then
        self.list_fonts.apply()
    end
    if rebuild_chrome then
        self._list_restore = nil
    end
    if self.home and not rebuild_chrome then
        if self.home.title_bar then
            self.home.title_bar:setTitle(self:menuTitle())
            if self.home.title_bar.setSubTitle then
                self.home.title_bar:setSubTitle("")
            end
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
    if not self.home or self.viewer then return end
    -- Second nextTick: onClose already defers on_back once; wait for viewer
    -- teardown + home repaint before Menu/font refresh (Kindle FreeType races).
    UIManager:nextTick(function()
        if not self.home or self.viewer then return end
        pcall(function()
            if self.home.title_bar then
                self.home.title_bar:setTitle(self:menuTitle())
                if self.home.title_bar.setSubTitle then
                    self.home.title_bar:setSubTitle("")
                end
            end
            self.home:updateList()
            UIManager:setDirty(self.home, "ui")
        end)
    end)
end

function Plugin:loadViewerImages(article, viewer)
    if not viewer or viewer ~= self.viewer or viewer._closing or not viewer.show_images then return end
    local raw = tostring(article and article.html or "")
    local urls = Images.extractImageUrls(raw)
    if #urls == 0 then return end
    local data_dir = self.cache.root
    local img_dir = Images.ensureDirectory(Images.directory(data_dir))
    local cached_map = select(1, Images.cachedMap(raw, data_dir))
    local need_download = false
    for _, url in ipairs(urls) do
        local norm = Images.normalizeUrl(url)
        if not cached_map[norm] then
            need_download = true
            break
        end
    end
    local function mapAlreadyApplied()
        local existing = viewer.image_map
        return existing and next(existing) ~= nil
    end
    if not need_download then
        -- openArticle already painted placeholders; apply cached map only if still empty.
        if next(cached_map) and not mapAlreadyApplied() then
            viewer:applyImageMap(cached_map, img_dir)
        end
        return
    end
    if not NetworkMgr:isOnline() then
        if next(cached_map) and not mapAlreadyApplied() then
            viewer:applyImageMap(cached_map, img_dir)
        end
        return
    end
    -- Avoid contending with an in-flight sync's HTTP/SSL on Kindle.
    if self.syncing then
        if next(cached_map) and not mapAlreadyApplied() then
            viewer:applyImageMap(cached_map, img_dir)
        end
        self:_scheduleArticleOpenTask(Plugin.ARTICLE_OPEN_DEFER_IMAGES_RETRY, function()
            if self.viewer ~= viewer or viewer._closing or self.syncing then return end
            self:loadViewerImages(article, viewer)
        end)
        return
    end
    local ok_prep, map, dir, downloaded = pcall(function()
        return Images.prepare(raw, {
            data_dir = data_dir,
            download = true,
            is_online = true,
        })
    end)
    if not ok_prep or viewer ~= self.viewer or viewer._closing then return end
    if (downloaded and downloaded > 0) or (map and next(map)) then
        viewer:applyImageMap(map, dir or img_dir)
        if downloaded and downloaded > 0 then
            Notification:notify(
                string.format("Loaded %d image%s", downloaded, downloaded == 1 and "" or "s"),
                Notification.SOURCE_ALWAYS_SHOW
            )
        end
    end
end

function Plugin:openArticle(id, nav_ids)
    -- Always drop prior stages first (close / Prev / Next / failed reopen).
    self:cancelArticleOpenTasks()

    local article = self.cache:getArticle(id)
    if not article then return end

    self:rememberListPosition()
    if self._list_restore then
        self._list_restore.article_id = id
    end

    -- Use a stable ordered snapshot for this viewer session. Opening marks the
    -- article read; re-querying an unread browse list would drop it and break
    -- Prev / shift Next / stale N/M indices.
    local ids = nav_ids
    if type(ids) ~= "table" then
        ids = self:articleIds()
    end
    local index, prev_id, next_id = Nav.neighbors(ids, id)
    if not index then
        ids = self:articleIds()
        index, prev_id, next_id = Nav.neighbors(ids, id)
    end
    if not index then
        ids = { id }
        index, prev_id, next_id = 1, nil, nil
    end

    local mark_on_open = self:markReadOnOpen()
    if mark_on_open then
        -- Local-only: never HTTP mark-read on the UI thread (15s socket hang).
        -- Flush happens on explicit Sync via flushQueue.
        article.unread = false
        self.cache:putArticle(article)
        self.sync:queueAction(id, "read", true)
    end

    local function reopen(neighbor_id)
        local old = self.viewer
        if old then
            self:cancelArticleOpenTasks()
            self.viewer = nil
            if old.onClose then
                -- Prev/next: close without refreshHomeAfterViewer (callbacks cleared).
                old.callbacks = {}
                old:onClose()
            else
                UIManager:close(old, "flashui")
            end
        end
        self:openArticle(neighbor_id, ids)
    end

    local data_dir = self.cache.root
    local show_images = Renderer.readShowImages()
    -- Text-first open: never scan image cache or rewrite maps before UIManager:show.
    -- Cached images / downloads reinit MuPDF after first paint settles.
    local image_map, resource_dir = {}, nil
    if show_images then
        resource_dir = Images.ensureDirectory(Images.directory(data_dir))
    end

    local function openOriginal()
        local href = article.url
        if not href or href == "" then
            UIManager:show(InfoMessage:new{ text = "No original link for this article." })
            return
        end
        UIManager:show(ConfirmBox:new{
            text = "Open original?\n" .. tostring(href),
            ok_text = "Open",
            ok_callback = function()
                if Device.openLink then
                    Device:openLink(href)
                else
                    UIManager:show(InfoMessage:new{ text = tostring(href) })
                end
            end,
        })
    end

    local widget
    local ok_widget, widget_or_err = pcall(function()
        return Renderer:articleWidget(article, {
        index = index,
        total = #ids,
        prev_id = prev_id,
        next_id = next_id,
        icons = self.icons,
        data_dir = data_dir,
        image_map = image_map,
        html_resource_directory = resource_dir,
        on_detach = function()
            self:cancelArticleOpenTasks()
            if self.viewer == widget then
                self.viewer = nil
            end
        end,
        on_back = function()
            -- Viewer X / Back: refresh list only — never rebuild/close Home.
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
            -- putArticle pins to favorites/ when starred, unpins when unstarred.
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
        on_open_original = openOriginal,
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
    end)
    if not ok_widget or not widget_or_err then
        UIManager:show(InfoMessage:new{
            text = "Unable to open this article on this device.\n"
                .. tostring(widget_or_err or "render failed"),
        })
        return
    end
    widget = widget_or_err
    self.viewer = widget
    UIManager:show(widget, "ui")
    -- Kindle Paperwhite: api.lua uses socketutil:set_timeout(15, 30). Running
    -- sync applyAction / Images.prepare in nextTick after show freezes the event
    -- loop for up to that full 15s block timeout (seen as "not painting 2 covered
    -- widget(s)" with no input). First paint = text-only shell; stage the rest.
    UIManager:forceRePaint()

    -- Stage 1: apply locally cached images only (disk). One MuPDF reinit.
    -- Always deferred — even when cache is warm — so second open never sync-reinits
    -- before / during first paint of the new viewer.
    self:_scheduleArticleOpenTask(Plugin.ARTICLE_OPEN_DEFER_CACHED_IMAGES, function()
        if self.viewer ~= widget or widget._closing then return end
        if not widget.show_images then return end
        local ok, cached_map, cached_dir = pcall(function()
            return Images.cachedMap(article.html or "", self.cache.root)
        end)
        if not ok or not cached_map or not next(cached_map) then return end
        if widget.image_map and next(widget.image_map) then return end
        local dir = Images.ensureDirectory(cached_dir or Images.directory(self.cache.root))
        pcall(function()
            widget:applyImageMap(cached_map, dir)
        end)
    end)

    -- Stage 2: network image fetches (also blocking HTTP — after interactivity).
    self:_scheduleArticleOpenTask(Plugin.ARTICLE_OPEN_DEFER_DOWNLOAD, function()
        if self.viewer ~= widget or widget._closing then return end
        self:loadViewerImages(article, widget)
    end)
end

return Plugin
