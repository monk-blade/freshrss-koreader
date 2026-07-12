local Sync = {}
Sync.__index = Sync

local READ_STATE = "user/-/state/com.google/read"
local STARRED_STATE = "user/-/state/com.google/starred"
local DEFAULT_ARTICLE_CAP = 100
local MIN_ARTICLE_CAP = 20
local MAX_ARTICLE_CAP = 500
local PAGE_SIZE = 100
local MAX_SYNC_IMAGES = 50

-- Prefer settings-backed budget when Images module is wired; else constant.
local function hasCategory(categories, state_id)
    if type(categories) ~= "table" then return false end
    for _, category in ipairs(categories) do
        local id = type(category) == "table" and category.id or category
        if id == state_id then return true end
    end
    return false
end

local LABEL_PREFIX = "user/-/label/"

local function labelsFromCategories(categories)
    local labels = {}
    if type(categories) ~= "table" then return labels end
    for _, category in ipairs(categories) do
        local id = type(category) == "table" and category.id or category
        if type(id) == "string" and id:sub(1, #LABEL_PREFIX) == LABEL_PREFIX then
            table.insert(labels, id)
        end
    end
    return labels
end

local function articleFromRaw(raw, old)
    old = old or {}
    local server_unread = not hasCategory(raw.categories, READ_STATE)
    local server_starred = hasCategory(raw.categories, STARRED_STATE)
    return {
        id = tostring(raw.id or raw.crawlTimeMsec or ""),
        title = raw.title or "Untitled",
        author = raw.author,
        feed_title = raw.origin and raw.origin.title or "FreshRSS",
        feed_id = raw.origin and raw.origin.streamId or old.feed_id,
        url = raw.alternate and raw.alternate[1] and raw.alternate[1].href,
        published = raw.published,
        updated = raw.updated,
        html = raw.summary and raw.summary.content or raw.content and raw.content.content or "",
        unread = server_unread and (old.unread ~= false),
        starred = server_starred or old.starred == true,
        labels = labelsFromCategories(raw.categories),
    }
end

local function report(on_progress, stage, ratio)
    if on_progress then on_progress(stage, ratio) end
end

function Sync:new(cache, settings)
    return setmetatable({ cache = cache, settings = settings }, self)
end

function Sync:syncOptions(browse)
    browse = browse or {}
    local raw_max = self.settings:readSetting("freshrss_articles_per_sync")
    local max = DEFAULT_ARTICLE_CAP
    if raw_max ~= nil then
        max = tonumber(raw_max) or DEFAULT_ARTICLE_CAP
    end
    if max < MIN_ARTICLE_CAP then max = MIN_ARTICLE_CAP end
    if max > MAX_ARTICLE_CAP then max = MAX_ARTICLE_CAP end
    local unread_only = self.settings:readSetting("freshrss_sync_unread_only")
    if unread_only == nil then unread_only = true end
    local mode = browse.mode or "unread"
    -- Starred / feed / label streams should not force unread-only exclude unless user wants it
    -- for the default reading-list modes.
    local exclude_read = unread_only and true or false
    if mode == "starred" or mode == "all" then
        exclude_read = (mode == "all") and false or exclude_read
    end
    if mode == "all" then exclude_read = false end
    if mode == "starred" then exclude_read = false end
    return {
        max_articles = max,
        exclude_read = exclude_read,
        page_size = math.min(PAGE_SIZE, max),
        stream_id = self:streamIdForBrowse(browse),
    }
end

function Sync:streamIdForBrowse(browse)
    browse = browse or {}
    local mode = browse.mode or "unread"
    if mode == "starred" then
        return "user/-/state/com.google/starred"
    elseif mode == "feed" and browse.feed_id and browse.feed_id ~= "" then
        return browse.feed_id
    elseif mode == "label" and browse.label and browse.label ~= "" then
        return browse.label
    end
    return "user/-/state/com.google/reading-list"
end

-- Fetch stream pages until continuation ends or max_articles is reached.
-- browse: optional { mode, feed_id, label }; stream_id overrides when provided.
function Sync:fetchAllStreamItems(api, stream_id, on_progress, browse)
    local opts = self:syncOptions(browse)
    local sid = stream_id or opts.stream_id
    local items = {}
    local continuation
    local pages = 0
    while #items < opts.max_articles do
        pages = pages + 1
        local n = math.min(opts.page_size, opts.max_articles - #items)
        local ratio = 0.55 + 0.30 * (#items / opts.max_articles)
        report(on_progress, "stream", ratio)
        local stream, err = api:stream(sid, {
            n = n,
            exclude_read = opts.exclude_read,
            continuation = continuation,
        })
        if not stream or type(stream.items) ~= "table" then
            if #items == 0 then
                return nil, err or "FreshRSS returned no article stream"
            end
            break
        end
        if #stream.items == 0 then break end
        for _, raw in ipairs(stream.items) do
            if #items >= opts.max_articles then break end
            table.insert(items, raw)
        end
        if #items >= opts.max_articles then break end
        continuation = stream.continuation
        if not continuation or tostring(continuation) == "" then break end
        if pages >= 50 then break end
    end
    opts.stream_id = sid
    return items, nil, opts
end

function Sync:storeStreamItems(items)
    local stored = 0
    for _, raw in ipairs(items) do
        local id = tostring(raw.id or raw.crawlTimeMsec or "")
        if id ~= "" then
            local old = self.cache:getArticle(id) or {}
            self.cache:putArticle(articleFromRaw(raw, old))
            stored = stored + 1
        end
    end
    return stored
end

---Prefetch article images during sync (capped globally, bounded parallel downloads).
function Sync:prefetchImages(items, on_progress)
    local Images = self.images
    if not Images then return { downloaded = 0 } end
    local show_images = self.settings:readSetting("freshrss_viewer_show_images")
    if show_images == false then return { downloaded = 0 } end

    local data_dir = self.cache and self.cache.root or ""
    if data_dir == "" then return { downloaded = 0 } end
    local dir = Images.ensureDirectory(Images.directory(data_dir))
    local jobs = {}
    local seen = {}
    local sync_budget = Images.readSyncBudget and Images.readSyncBudget() or MAX_SYNC_IMAGES
    local max_parallel = Images.readMaxParallel and Images.readMaxParallel() or Images.MAX_PARALLEL

    for _, raw in ipairs(items) do
        if #jobs >= sync_budget then break end
        local html = raw.summary and raw.summary.content or raw.content and raw.content.content or ""
        if html ~= "" then
            for _, url in ipairs(Images.extractImageUrls(html)) do
                if #jobs >= sync_budget then break end
                local norm = Images.normalizeUrl(url)
                if not seen[norm] and not Images.findCachedFilename(dir, norm) then
                    seen[norm] = true
                    jobs[#jobs + 1] = {
                        url = norm,
                        dir = dir,
                        filename = Images.filenameForUrl(norm),
                    }
                end
            end
        end
    end

    if #jobs == 0 then
        report(on_progress, "images", 0.98)
        return { downloaded = 0 }
    end

    local _, total_downloaded = Images.downloadMany(jobs, {
        max_parallel = max_parallel,
        max_success = sync_budget,
        on_progress = function(done, total)
            if total > 0 then
                report(on_progress, "images", 0.92 + 0.06 * (done / total))
            end
        end,
    })
    report(on_progress, "images", 0.98)
    return { downloaded = total_downloaded or 0 }
end

function Sync:refreshAfterLogin(api, stream_id, on_progress, browse)
    report(on_progress, "meta", 0.40)
    local subscriptions = api:listSubscriptions()
    local tags = api:listTags()
    local counts = api:unreadCount()
    if self.cache.setMeta then
        self.cache:setMeta({
            subscriptions = subscriptions,
            tags = tags,
            counts = counts,
            updated = os.time(),
        })
    end

    report(on_progress, "stream", 0.55)
    local items, err, opts = self:fetchAllStreamItems(api, stream_id, on_progress, browse)
    if not items then return false, err end

    report(on_progress, "cache", 0.90)
    local stored = self:storeStreamItems(items)
    report(on_progress, "images", 0.92)
    local img_stats = self:prefetchImages(items, on_progress)
    self.settings:saveSetting("freshrss_last_sync", os.time())
    self.settings:saveSetting("last_sync", os.time())
    self.settings:flush()
    local flush_stats = self:flushQueue(api)
    report(on_progress, "done", 1.0)
    return true, {
        subscriptions = subscriptions,
        tags = tags,
        counts = counts,
        fetched = stored,
        exclude_read = opts.exclude_read,
        max_articles = opts.max_articles,
        stream_id = opts.stream_id,
        flushed = flush_stats.flushed,
        flush_failed = flush_stats.failed,
        images_downloaded = img_stats and img_stats.downloaded or 0,
    }
end

function Sync:refresh(api, stream_id, on_progress, browse)
    report(on_progress, "login", 0.10)
    local ok, err = api:login()
    if not ok then return false, err end
    return self:refreshAfterLogin(api, stream_id, on_progress, browse)
end

function Sync:refreshAsync(api, stream_id, callback, on_progress, browse)
    report(on_progress, "login", 0.10)
    api:loginAsync(function(logged_in, login_error)
        if not logged_in then callback(false, login_error); return end
        local ok, result = self:refreshAfterLogin(api, stream_id, on_progress, browse)
        callback(ok, result)
    end)
end

function Sync:markAllAsRead(api, stream_id)
    local logged_in, login_error = api:login()
    if not logged_in then return false, login_error end
    local ok, err = api:markAllAsRead(stream_id, os.time())
    if not ok then
        api:invalidateSession()
        if api:login() then
            ok, err = api:markAllAsRead(stream_id, os.time())
        end
    end
    return ok, err
end

function Sync:queueAction(id, action, state)
    self.cache:queue({ id = tostring(id), action = action, state = state, created = os.time() })
end

function Sync:applyAction(api, id, action, state)
    local logged_in, login_error = api:login()
    if not logged_in then
        self:queueAction(id, action, state)
        return false, login_error
    end
    local ok, error_message = api:editTag(tostring(id), action, state)
    if not ok then
        api:invalidateSession()
        local relogged = api:login()
        if relogged then ok, error_message = api:editTag(tostring(id), action, state) end
        if not ok then
            self:queueAction(id, action, state)
            return false, error_message
        end
    end
    return true
end

function Sync:flushQueue(api)
    local flushed, failed = 0, 0
    while #self.cache:queuedActions() > 0 do
        local action = self.cache:dequeue()
        local ok = api:editTag(action.id, action.action, action.state)
        if not ok then
            api:invalidateSession()
            if not api:login() then
                self:queueAction(action.id, action.action, action.state)
                failed = failed + 1
                break
            end
            ok = api:editTag(action.id, action.action, action.state)
            if not ok then
                self:queueAction(action.id, action.action, action.state)
                failed = failed + 1
                break
            end
        end
        flushed = flushed + 1
    end
    return { flushed = flushed, failed = failed }
end

-- Exported for unit tests / settings UI
Sync._articleFromRaw = articleFromRaw
Sync._hasCategory = hasCategory
Sync._labelsFromCategories = labelsFromCategories
Sync.DEFAULT_ARTICLE_CAP = DEFAULT_ARTICLE_CAP
Sync.ARTICLE_CAPS = { 50, 100, 200, 300 }
Sync.MAX_SYNC_IMAGES = MAX_SYNC_IMAGES
Sync.READING_LIST = "user/-/state/com.google/reading-list"
Sync.STARRED = "user/-/state/com.google/starred"

return Sync
