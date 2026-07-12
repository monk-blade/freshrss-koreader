local Sync = {}
Sync.__index = Sync

local READ_STATE = "user/-/state/com.google/read"
local STARRED_STATE = "user/-/state/com.google/starred"
local DEFAULT_ARTICLE_CAP = 100
local MIN_ARTICLE_CAP = 20
local MAX_ARTICLE_CAP = 500

function Sync.clampArticleCap(raw)
    local max = tonumber(raw) or DEFAULT_ARTICLE_CAP
    if max < MIN_ARTICLE_CAP then max = MIN_ARTICLE_CAP end
    if max > MAX_ARTICLE_CAP then max = MAX_ARTICLE_CAP end
    return max
end

function Sync.readArticleCap(settings)
    if not settings or not settings.readSetting then
        return DEFAULT_ARTICLE_CAP
    end
    return Sync.clampArticleCap(settings:readSetting("freshrss_articles_per_sync"))
end

function Sync.saveArticleCap(settings, value)
    if not settings or not settings.saveSetting then return Sync.clampArticleCap(value) end
    local max = Sync.clampArticleCap(value)
    settings:saveSetting("freshrss_articles_per_sync", max)
    if settings.flush then settings:flush() end
    return max
end
local PAGE_SIZE = 100
local MAX_SYNC_IMAGES = 50
local EDIT_TAG_BATCH = 40
local CONTENTS_BATCH = 40

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
    local published = raw.published
    local updated = raw.updated
    -- Prefer updated, then published, then crawlTimeMsec (ms) so list dates always work.
    if updated == nil or updated == "" then updated = published end
    if (updated == nil or updated == "") and raw.crawlTimeMsec then
        local ms = tonumber(raw.crawlTimeMsec)
        if ms and ms > 0 then
            updated = ms > 1e12 and math.floor(ms / 1000) or ms
        end
    end
    if published == nil or published == "" then published = updated end
    return {
        id = tostring(raw.id or raw.crawlTimeMsec or ""),
        title = raw.title or "Untitled",
        author = raw.author,
        feed_title = raw.origin and raw.origin.title or "FreshRSS",
        feed_id = raw.origin and raw.origin.streamId or old.feed_id,
        url = raw.alternate and raw.alternate[1] and raw.alternate[1].href,
        published = published,
        updated = updated,
        html = raw.summary and raw.summary.content or raw.content and raw.content.content or "",
        unread = server_unread and (old.unread ~= false),
        starred = server_starred or old.starred == true,
        labels = labelsFromCategories(raw.categories),
    }
end

local function report(on_progress, stage, ratio, detail)
    if on_progress then on_progress(stage, ratio, detail) end
end

---Compact one-line label for the sync status strip (e-ink friendly).
function Sync.formatProgressLabel(stage, detail)
    detail = detail or {}
    if stage == "login" then
        return "Signing in…"
    elseif stage == "queue" then
        local pending = detail.pending
        if pending and pending > 0 then
            local flushed = detail.flushed or 0
            return string.format("Queue · %d/%d", flushed, pending)
        end
        return "Flushing queue…"
    elseif stage == "meta" then
        local subs = detail.subscriptions
        if subs and subs > 0 then
            return string.format("Feeds · %d", subs)
        end
        return "Loading feeds…"
    elseif stage == "stream" then
        if detail.found and detail.found > 0 then
            return string.format("IDs · %d found", detail.found)
        end
        return "Fetching article IDs…"
    elseif stage == "cache" then
        local total = detail.total
        local found = detail.found
        local skipped = detail.skipped
        local done = detail.done or 0
        if total and total > 0 and done < total then
            return string.format("Articles · %d/%d", done, total)
        end
        if found and found > 0 then
            if skipped and skipped > 0 then
                return string.format("Articles · %d new / %d skipped / %d ids",
                    total or 0, skipped, found)
            end
            if total and total >= 0 then
                return string.format("Articles · %d new / %d ids", total, found)
            end
            return string.format("Articles · 0 new / %d ids", found)
        end
        if total and total > 0 then
            return string.format("Articles · %d/%d", done, total)
        end
        return "Downloading articles…"
    elseif stage == "images" then
        local total = detail.total
        if total and total > 0 then
            return string.format("Images · %d/%d", detail.done or 0, total)
        end
        return "Prefetching images…"
    elseif stage == "done" then
        local failed = detail.failed or 0
        if failed > 0 then
            return string.format("Done · %d queue failed", failed)
        end
        return "Done"
    end
    return "Syncing…"
end

function Sync:new(cache, settings)
    return setmetatable({ cache = cache, settings = settings, _cancel_requested = false }, self)
end

function Sync:resetCancel()
    self._cancel_requested = false
end

function Sync:requestCancel()
    self._cancel_requested = true
end

function Sync:cancelled()
    return self._cancel_requested == true
end

Sync.SCOPE_CURRENT = "current_view"
Sync.SCOPE_READING_LIST = "reading_list"
Sync.READING_LIST = "user/-/state/com.google/reading-list"
Sync.STARRED = "user/-/state/com.google/starred"

function Sync.readSyncScope(settings)
    local value = settings and settings.readSetting and settings:readSetting("freshrss_sync_scope")
    if value == Sync.SCOPE_READING_LIST then
        return Sync.SCOPE_READING_LIST
    end
    return Sync.SCOPE_CURRENT
end

function Sync.cycleSyncScope(settings)
    local next_scope = Sync.readSyncScope(settings) == Sync.SCOPE_READING_LIST
        and Sync.SCOPE_CURRENT
        or Sync.SCOPE_READING_LIST
    settings:saveSetting("freshrss_sync_scope", next_scope)
    if settings.flush then settings:flush() end
    return next_scope
end

function Sync:syncOptions(browse)
    browse = browse or {}
    local max = Sync.readArticleCap(self.settings)
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
        stream_id = self:resolveStreamId(browse),
        sync_scope = Sync.readSyncScope(self.settings),
    }
end

function Sync:streamIdForBrowse(browse)
    browse = browse or {}
    local mode = browse.mode or "unread"
    if mode == "starred" then
        return Sync.STARRED
    elseif mode == "feed" and browse.feed_id and browse.feed_id ~= "" then
        return browse.feed_id
    elseif mode == "label" and browse.label and browse.label ~= "" then
        return browse.label
    end
    return Sync.READING_LIST
end

---Honor freshrss_sync_scope: current_view (default) vs always reading-list.
function Sync:resolveStreamId(browse)
    if Sync.readSyncScope(self.settings) == Sync.SCOPE_READING_LIST then
        return Sync.READING_LIST
    end
    return self:streamIdForBrowse(browse)
end

---Human label for sync toast / progress (feed title, category, Starred, Reading list).
function Sync.streamLabel(browse, stream_id, cache)
    browse = browse or {}
    local sid = tostring(stream_id or "")
    if sid == Sync.STARRED or browse.mode == "starred" then
        return "Starred"
    end
    if sid == Sync.READING_LIST or sid == "" then
        return "Reading list"
    end
    if browse.mode == "label" and browse.label then
        local name = tostring(browse.label):gsub("^user/%-/label/", "")
        return name ~= "" and name or "Category"
    end
    if browse.mode == "feed" and browse.feed_id then
        if cache and cache.getMeta then
            local meta = cache:getMeta()
            local subs = meta.subscriptions and meta.subscriptions.subscriptions or {}
            for _, sub in ipairs(subs) do
                local id = sub.id or sub.feedId
                if id == browse.feed_id then
                    return sub.title or tostring(id)
                end
            end
        end
        return tostring(browse.feed_id)
    end
    -- Feed id without browse context (e.g. scope forced reading-list already handled).
    if sid:find("feed/", 1, true) and cache and cache.getMeta then
        local meta = cache:getMeta()
        local subs = meta.subscriptions and meta.subscriptions.subscriptions or {}
        for _, sub in ipairs(subs) do
            local id = sub.id or sub.feedId
            if tostring(id) == sid then
                return sub.title or sid
            end
        end
    end
    if sid:find("user/-/label/", 1, true) then
        return sid:gsub("^user/%-/label/", "")
    end
    return "Reading list"
end

local function articleCached(cache, id)
    if cache.hasArticle then
        return cache:hasArticle(id)
    end
    return cache:getArticle(id) ~= nil
end

-- Enumerate stream item ids, then fetch contents only for cache misses.
-- browse: optional { mode, feed_id, label }; stream_id overrides when provided.
function Sync:fetchAllStreamItems(api, stream_id, on_progress, browse)
    local opts = self:syncOptions(browse)
    local sid = stream_id or opts.stream_id
    local all_ids = {}
    local continuation
    local pages = 0
    while #all_ids < opts.max_articles do
        if self:cancelled() then
            opts.stream_id = sid
            opts.ids_seen = #all_ids
            opts.ids_missing = 0
            opts.ids_skipped = 0
            return {}, "cancelled", opts
        end
        pages = pages + 1
        local n = math.min(opts.page_size, opts.max_articles - #all_ids)
        local page, err = api:streamItemIds(sid, {
            n = n,
            exclude_read = opts.exclude_read,
            continuation = continuation,
        })
        if not page or type(page.ids) ~= "table" then
            if #all_ids == 0 then
                return nil, err or "FreshRSS returned no article ids"
            end
            break
        end
        if #page.ids == 0 then break end
        for _, id in ipairs(page.ids) do
            if #all_ids >= opts.max_articles then break end
            table.insert(all_ids, id)
        end
        local ratio = 0.55 + 0.20 * (#all_ids / opts.max_articles)
        report(on_progress, "stream", ratio, { found = #all_ids, max = opts.max_articles })
        if #all_ids >= opts.max_articles then break end
        continuation = page.continuation
        if not continuation or tostring(continuation) == "" then break end
        if pages >= 50 then break end
    end

    local missing = {}
    for _, id in ipairs(all_ids) do
        if not articleCached(self.cache, id) then
            table.insert(missing, id)
        end
    end
    local skipped = #all_ids - #missing

    local items = {}
    if #missing == 0 then
        report(on_progress, "cache", 0.90, { done = 0, total = 0, found = #all_ids, skipped = skipped })
    end
    local batch = CONTENTS_BATCH
    if api.CONTENTS_BATCH then batch = api.CONTENTS_BATCH end
    for i = 1, #missing, batch do
        if self:cancelled() then
            opts.stream_id = sid
            opts.ids_seen = #all_ids
            opts.ids_missing = #missing
            opts.ids_skipped = skipped
            return items, "cancelled", opts
        end
        local chunk = {}
        for j = i, math.min(i + batch - 1, #missing) do
            table.insert(chunk, missing[j])
        end
        local done_count = math.min(i + batch - 1, #missing)
        local ratio = 0.75 + 0.15 * (done_count / math.max(#missing, 1))
        report(on_progress, "cache", ratio, {
            done = done_count,
            total = #missing,
            found = #all_ids,
            skipped = skipped,
        })
        local contents, err = api:streamItemContents(chunk)
        if not contents or type(contents.items) ~= "table" then
            if #items == 0 and #missing > 0 then
                return nil, err or "FreshRSS returned no article contents"
            end
            break
        end
        for _, raw in ipairs(contents.items) do
            table.insert(items, raw)
        end
        if self:cancelled() then
            opts.stream_id = sid
            opts.ids_seen = #all_ids
            opts.ids_missing = #missing
            opts.ids_skipped = skipped
            return items, "cancelled", opts
        end
    end

    opts.stream_id = sid
    opts.ids_seen = #all_ids
    opts.ids_missing = #missing
    opts.ids_skipped = skipped
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
        report(on_progress, "images", 0.98, { done = 0, total = 0 })
        return { downloaded = 0 }
    end

    local _, total_downloaded = Images.downloadMany(jobs, {
        max_parallel = max_parallel,
        max_success = sync_budget,
        should_cancel = function() return self:cancelled() end,
        on_progress = function(done, total)
            if total > 0 then
                report(on_progress, "images", 0.92 + 0.06 * (done / total), { done = done, total = total })
            end
        end,
    })
    report(on_progress, "images", 0.98, { done = total_downloaded or 0, total = #jobs })
    return { downloaded = total_downloaded or 0 }
end

local function cancelledResult(self, browse, opts, extra)
    extra = extra or {}
    opts = opts or {}
    local sid = opts.stream_id or self:resolveStreamId(browse)
    return false, {
        cancelled = true,
        fetched = extra.fetched or 0,
        stream_id = sid,
        stream_label = Sync.streamLabel(browse, sid, self.cache),
        ids_seen = opts.ids_seen or extra.ids_seen or 0,
        ids_skipped = opts.ids_skipped or extra.ids_skipped or 0,
        flushed = extra.flushed or 0,
        flush_failed = extra.flush_failed or 0,
        exclude_read = opts.exclude_read,
        max_articles = opts.max_articles,
    }
end

function Sync:refreshAfterLogin(api, stream_id, on_progress, browse)
    -- Flush queued mark/star actions before fetching so server state is current.
    local flush_stats = self:flushQueue(api, on_progress)
    if self:cancelled() then
        return cancelledResult(self, browse, self:syncOptions(browse), {
            flushed = flush_stats.flushed,
            flush_failed = flush_stats.failed,
        })
    end

    report(on_progress, "meta", 0.40)
    local subscriptions = api:listSubscriptions()
    local tags = api:listTags()
    local counts = api:unreadCount()
    local sub_count = 0
    if type(subscriptions) == "table" and type(subscriptions.subscriptions) == "table" then
        sub_count = #subscriptions.subscriptions
    end
    report(on_progress, "meta", 0.45, { subscriptions = sub_count })
    if self:cancelled() then
        return cancelledResult(self, browse, self:syncOptions(browse), {
            flushed = flush_stats.flushed,
            flush_failed = flush_stats.failed,
        })
    end
    if self.cache.setMeta then
        self.cache:setMeta({
            subscriptions = subscriptions,
            tags = tags,
            counts = counts,
            updated = os.time(),
        })
    end

    local items, err, opts = self:fetchAllStreamItems(api, stream_id, on_progress, browse)
    if err == "cancelled" then
        local stored = self:storeStreamItems(items or {})
        return cancelledResult(self, browse, opts, {
            fetched = stored,
            flushed = flush_stats.flushed,
            flush_failed = flush_stats.failed,
        })
    end
    if not items then return false, err end
    if self:cancelled() then
        local stored = self:storeStreamItems(items)
        return cancelledResult(self, browse, opts, {
            fetched = stored,
            flushed = flush_stats.flushed,
            flush_failed = flush_stats.failed,
        })
    end

    report(on_progress, "cache", 0.90, {
        done = opts.ids_missing or 0,
        total = opts.ids_missing or 0,
        found = opts.ids_seen or 0,
        skipped = opts.ids_skipped or 0,
    })
    local stored = self:storeStreamItems(items)

    local evicted = 0
    local purged = 0
    if self.cache.evictOldest then
        local retain = 1000
        if self.settings and self.settings.readSetting then
            retain = tonumber(self.settings:readSetting("freshrss_cache_max_articles")) or 1000
        end
        local caps = { [500] = true, [1000] = true, [2000] = true, [5000] = true }
        if not caps[retain] then retain = 1000 end
        evicted = self.cache:evictOldest(retain)
    end
    if self.images and self.images.purgeOrphans and self.images.referencedFilenames then
        local keep = self.images.referencedFilenames(self.cache)
        purged = self.images.purgeOrphans(self.cache.root, keep)
    end

    report(on_progress, "images", 0.92, { done = 0, total = 0 })
    if self:cancelled() then
        return cancelledResult(self, browse, opts, {
            fetched = stored,
            flushed = flush_stats.flushed,
            flush_failed = flush_stats.failed,
            evicted = evicted,
            images_purged = purged,
        })
    end
    local img_stats = self:prefetchImages(items, on_progress)
    if self:cancelled() then
        return cancelledResult(self, browse, opts, {
            fetched = stored,
            flushed = flush_stats.flushed,
            flush_failed = flush_stats.failed,
            evicted = evicted,
            images_purged = purged,
            images_downloaded = img_stats and img_stats.downloaded or 0,
        })
    end
    self.settings:saveSetting("freshrss_last_sync", os.time())
    self.settings:saveSetting("last_sync", os.time())
    self.settings:flush()
    report(on_progress, "done", 1.0, { failed = flush_stats.failed or 0 })
    return true, {
        subscriptions = subscriptions,
        tags = tags,
        counts = counts,
        fetched = stored,
        exclude_read = opts.exclude_read,
        max_articles = opts.max_articles,
        stream_id = opts.stream_id,
        stream_label = Sync.streamLabel(browse, opts.stream_id, self.cache),
        ids_seen = opts.ids_seen,
        ids_skipped = opts.ids_skipped,
        flushed = flush_stats.flushed,
        flush_failed = flush_stats.failed,
        images_downloaded = img_stats and img_stats.downloaded or 0,
        evicted = evicted,
        images_purged = purged,
    }
end

function Sync:refresh(api, stream_id, on_progress, browse)
    self:resetCancel()
    report(on_progress, "login", 0.10)
    local ok, err = api:login()
    if not ok then return false, err end
    return self:refreshAfterLogin(api, stream_id, on_progress, browse)
end

function Sync:refreshAsync(api, stream_id, callback, on_progress, browse)
    self:resetCancel()
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

function Sync:flushQueue(api, on_progress)
    local pending = {}
    while #self.cache:queuedActions() > 0 do
        table.insert(pending, self.cache:dequeue())
    end
    if #pending == 0 then
        report(on_progress, "queue", 0.38, { pending = 0, flushed = 0, failed = 0 })
        return { flushed = 0, failed = 0 }
    end
    local total_pending = #pending
    report(on_progress, "queue", 0.35, { pending = total_pending, flushed = 0, failed = 0 })

    -- Preserve order of first appearance of each (action, state) group.
    local groups = {}
    local by_key = {}
    for _, action in ipairs(pending) do
        local key = tostring(action.action) .. "\0" .. tostring(action.state and true or false)
        local group = by_key[key]
        if not group then
            group = {
                action = action.action,
                state = action.state and true or false,
                ids = {},
                items = {},
            }
            by_key[key] = group
            table.insert(groups, group)
        end
        table.insert(group.ids, action.id)
        table.insert(group.items, action)
    end

    local flushed, failed = 0, 0
    local batch = EDIT_TAG_BATCH
    if api.EDIT_TAG_BATCH then batch = api.EDIT_TAG_BATCH end

    local function requeueFrom(list, start_index)
        for i = start_index, #list do
            local action = list[i]
            self:queueAction(action.id, action.action, action.state)
            failed = failed + 1
        end
    end

    for _, group in ipairs(groups) do
        for i = 1, #group.ids, batch do
            if self:cancelled() then
                requeueFrom(group.items, i)
                local seen = false
                for _, later in ipairs(groups) do
                    if later == group then
                        seen = true
                    elseif seen then
                        for _, action in ipairs(later.items) do
                            self:queueAction(action.id, action.action, action.state)
                            failed = failed + 1
                        end
                    end
                end
                return { flushed = flushed, failed = failed, cancelled = true }
            end
            local chunk_ids = {}
            local chunk_items = {}
            for j = i, math.min(i + batch - 1, #group.ids) do
                table.insert(chunk_ids, group.ids[j])
                table.insert(chunk_items, group.items[j])
            end
            local ok = api:editTagMany(chunk_ids, group.action, group.state)
            if not ok then
                api:invalidateSession()
                if not api:login() then
                    requeueFrom(group.items, i)
                    -- Requeue remaining groups untouched.
                    local seen = false
                    for _, later in ipairs(groups) do
                        if later == group then
                            seen = true
                        elseif seen then
                            for _, action in ipairs(later.items) do
                                self:queueAction(action.id, action.action, action.state)
                                failed = failed + 1
                            end
                        end
                    end
                    return { flushed = flushed, failed = failed }
                end
                ok = api:editTagMany(chunk_ids, group.action, group.state)
                if not ok then
                    requeueFrom(group.items, i)
                    local seen = false
                    for _, later in ipairs(groups) do
                        if later == group then
                            seen = true
                        elseif seen then
                            for _, action in ipairs(later.items) do
                                self:queueAction(action.id, action.action, action.state)
                                failed = failed + 1
                            end
                        end
                    end
                    return { flushed = flushed, failed = failed }
                end
            end
            flushed = flushed + #chunk_ids
            local queue_ratio = 0.35 + 0.05 * (flushed / total_pending)
            report(on_progress, "queue", queue_ratio, {
                pending = total_pending,
                flushed = flushed,
                failed = failed,
            })
        end
    end
    return { flushed = flushed, failed = failed }
end

-- Exported for unit tests / settings UI
Sync._articleFromRaw = articleFromRaw
Sync._hasCategory = hasCategory
Sync._labelsFromCategories = labelsFromCategories
Sync._articleCached = articleCached
Sync.DEFAULT_ARTICLE_CAP = DEFAULT_ARTICLE_CAP
Sync.MIN_ARTICLE_CAP = MIN_ARTICLE_CAP
Sync.MAX_ARTICLE_CAP = MAX_ARTICLE_CAP
Sync.ARTICLE_CAPS = { 50, 100, 200, 300 }
Sync.MAX_SYNC_IMAGES = MAX_SYNC_IMAGES

return Sync
