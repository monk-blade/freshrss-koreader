local lfs = require("libs/libkoreader-lfs")
local json = require("json")

local Cache = {}
Cache.__index = Cache

function Cache:new(root)
    lfs.mkdir(root)
    local o = setmetatable({ root = root, index_path = root .. "/index.json", index = {} }, self)
    local file = io.open(o.index_path, "r")
    if file then
        local ok, data = pcall(json.decode, file:read("*a"))
        file:close()
        if ok and type(data) == "table" then o.index = data end
    end
    -- Rehydrate permanently pinned favorites (survives index wipe / reinstall).
    o:loadPinnedFavorites()
    -- Older indexes often omitted published/updated; backfill so list shows "feed · date".
    o:backfillIndexDates()
    return o
end

function Cache:saveIndex()
    local file = assert(io.open(self.index_path, "w"))
    file:write(json.encode(self.index))
    file:close()
end

local function articleTimestamp(article)
    if not article then return nil end
    local ts = article.updated or article.published or article.crawlTimeMsec
    if ts == nil or ts == "" then return nil end
    local n = tonumber(ts)
    if not n or n <= 0 then return nil end
    if n > 1e12 then n = math.floor(n / 1000) end
    return n
end

function Cache:indexEntryFromArticle(article)
    local ts = articleTimestamp(article)
    return {
        id = tostring(article.id),
        title = article.title,
        feed_title = article.feed_title,
        feed_id = article.feed_id,
        unread = article.unread,
        starred = article.starred,
        updated = ts or article.updated,
        published = article.published or ts,
        labels = article.labels,
        pinned = article.starred and true or nil,
    }
end

---Fill missing index timestamps from on-disk article JSON (one-time repair).
function Cache:backfillIndexDates()
    local changed = 0
    for key, item in pairs(self.index) do
        if key ~= "_queue" and key ~= "_meta" and type(item) == "table" and item.id then
            if not articleTimestamp(item) then
                local article = self:getArticle(item.id)
                local ts = articleTimestamp(article)
                if ts then
                    item.updated = ts
                    item.published = article.published or ts
                    if article.feed_title and (not item.feed_title or item.feed_title == "") then
                        item.feed_title = article.feed_title
                    end
                    changed = changed + 1
                end
            elseif item.published == nil and item.updated ~= nil then
                item.published = item.updated
                changed = changed + 1
            end
        end
    end
    if changed > 0 then self:saveIndex() end
    return changed
end

function Cache:path(id)
    return self.root .. "/" .. tostring(id):gsub("[^%w_-]", "_") .. ".json"
end

function Cache:favoritesDir()
    return self.root .. "/favorites"
end

function Cache:favoritePath(id)
    return self:favoritesDir() .. "/" .. tostring(id):gsub("[^%w_-]", "_") .. ".json"
end

function Cache:isPinnedFavorite(id)
    id = tostring(id or "")
    if id == "" then return false end
    local f = io.open(self:favoritePath(id), "r")
    if not f then return false end
    f:close()
    return true
end

---Write a permanent copy under favorites/ (survives eviction / cache clean).
function Cache:pinFavorite(article)
    if not article or not article.id then return false end
    local dir = self:favoritesDir()
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    local path = self:favoritePath(article.id)
    local file = io.open(path, "w")
    if not file then return false end
    local copy = {}
    for k, v in pairs(article) do copy[k] = v end
    copy.starred = true
    copy.pinned = true
    file:write(json.encode(copy))
    file:close()
    return true
end

function Cache:unpinFavorite(id)
    id = tostring(id or "")
    if id == "" then return false end
    local path = self:favoritePath(id)
    if os.remove(path) then return true end
    return false
end

function Cache:putArticle(article)
    local id = tostring(article.id)
    local file = assert(io.open(self:path(id), "w"))
    file:write(json.encode(article))
    file:close()
    self.index[id] = self:indexEntryFromArticle(article)
    self:saveIndex()
    if article.starred then
        self:pinFavorite(article)
    elseif self:isPinnedFavorite(id) then
        self:unpinFavorite(id)
    end
end

function Cache:getArticle(id)
    id = tostring(id or "")
    local file = io.open(self:path(id), "r")
    if not file then
        file = io.open(self:favoritePath(id), "r")
    end
    if not file then return nil end
    local ok, value = pcall(json.decode, file:read("*a"))
    file:close()
    return ok and value or nil
end

function Cache:listArticles(feed_id)
    return self:listByMode("all", { feed_id = feed_id })
end

-- mode: all | unread | starred | feed | label
-- opts: feed_id, label
Cache.SORT_NEWEST = "newest"
Cache.SORT_OLDEST = "oldest"

function Cache.readListSort(settings)
    local value = settings and settings.readSetting and settings:readSetting("freshrss_list_sort")
    if value == Cache.SORT_OLDEST then
        return Cache.SORT_OLDEST
    end
    return Cache.SORT_NEWEST
end

function Cache.cycleListSort(settings)
    local next_sort = Cache.readListSort(settings) == Cache.SORT_OLDEST
        and Cache.SORT_NEWEST
        or Cache.SORT_OLDEST
    settings:saveSetting("freshrss_list_sort", next_sort)
    if settings.flush then settings:flush() end
    return next_sort
end

---Return a set map of hidden feed ids from settings.
function Cache.readHiddenFeeds(settings)
    local raw = settings and settings.readSetting and settings:readSetting("freshrss_hidden_feeds")
    local set = {}
    if type(raw) == "table" then
        for k, v in pairs(raw) do
            if type(k) == "number" and type(v) == "string" then
                set[v] = true
            elseif type(k) == "string" and v then
                set[k] = true
            end
        end
    end
    return set
end

function Cache.isFeedHidden(settings, feed_id)
    feed_id = tostring(feed_id or "")
    if feed_id == "" then return false end
    return Cache.readHiddenFeeds(settings)[feed_id] and true or false
end

function Cache.toggleHiddenFeed(settings, feed_id)
    feed_id = tostring(feed_id or "")
    if feed_id == "" then return false end
    local set = Cache.readHiddenFeeds(settings)
    local now_hidden
    if set[feed_id] then
        set[feed_id] = nil
        now_hidden = false
    else
        set[feed_id] = true
        now_hidden = true
    end
    local list = {}
    for id in pairs(set) do
        table.insert(list, id)
    end
    table.sort(list)
    settings:saveSetting("freshrss_hidden_feeds", list)
    if settings.flush then settings:flush() end
    return now_hidden
end

function Cache:listByMode(mode, opts)
    opts = opts or {}
    local hidden = opts.hidden_feeds
    local apply_hidden = opts.apply_hidden
    if apply_hidden == nil then
        apply_hidden = (mode == "all" or mode == "unread")
    end
    local result = {}
    for key, item in pairs(self.index) do
        if key ~= "_queue" and key ~= "_meta" and type(item) == "table" and item.id then
            local include = true
            if mode == "unread" then
                include = item.unread and true or false
            elseif mode == "starred" then
                include = item.starred and true or false
            elseif mode == "feed" or opts.feed_id then
                local want = opts.feed_id
                include = want == nil or item.feed_id == want
                if mode == "feed" and not want then include = false end
            elseif mode == "label" then
                include = false
                local want = opts.label
                if want and type(item.labels) == "table" then
                    for _, label in ipairs(item.labels) do
                        if label == want then include = true; break end
                    end
                end
            end
            -- "all" and leftover feed_id filter from listArticles
            if mode == "all" and opts.feed_id then
                include = item.feed_id == opts.feed_id
            end
            if include and apply_hidden and hidden and item.feed_id and hidden[tostring(item.feed_id)] then
                include = false
            end
            if include then
                table.insert(result, item)
            end
        end
    end
    local sort = opts.sort or Cache.SORT_NEWEST
    if sort == Cache.SORT_OLDEST then
        table.sort(result, function(a, b) return tostring(a.updated or "") < tostring(b.updated or "") end)
    else
        table.sort(result, function(a, b) return tostring(a.updated or "") > tostring(b.updated or "") end)
    end
    return result
end

function Cache:unreadCount()
    local count = 0
    for key, item in pairs(self.index) do
        if key ~= "_queue" and key ~= "_meta" and type(item) == "table" and item.id and item.unread then
            count = count + 1
        end
    end
    return count
end

---Unread count for the current browse context (feed / label / starred / global).
---Prefers FreshRSS unread-count meta for feed/label streams; falls back to local index.
function Cache:unreadCountForBrowse(browse)
    browse = browse or {}
    local mode = browse.mode or "unread"
    if mode == "feed" and browse.feed_id and browse.feed_id ~= "" then
        local from_meta = self:unreadCountForStream(browse.feed_id)
        if from_meta ~= nil then return from_meta end
        local n = 0
        for _, item in ipairs(self:listByMode("feed", { feed_id = browse.feed_id, apply_hidden = false })) do
            if item.unread then n = n + 1 end
        end
        return n
    end
    if mode == "label" and browse.label and browse.label ~= "" then
        local from_meta = self:unreadCountForStream(browse.label)
        if from_meta ~= nil then return from_meta end
        local n = 0
        for _, item in ipairs(self:listByMode("label", { label = browse.label, apply_hidden = false })) do
            if item.unread then n = n + 1 end
        end
        return n
    end
    if mode == "starred" then
        local n = 0
        for _, item in ipairs(self:listByMode("starred", { apply_hidden = false })) do
            if item.unread then n = n + 1 end
        end
        return n
    end
    return self:unreadCount()
end

---Unread count for one stream id from last sync's unread-count meta (or nil).
function Cache:unreadCountForStream(stream_id)
    if stream_id == nil or stream_id == "" then return nil end
    local meta = self:getMeta()
    local counts = meta.counts
    if type(counts) ~= "table" then return nil end
    local list = counts.unreadcounts
    if type(list) ~= "table" then return nil end
    local want = tostring(stream_id)
    for _, row in ipairs(list) do
        if type(row) == "table" and tostring(row.id) == want then
            return tonumber(row.count)
        end
    end
    return nil
end

-- Mark matching unread articles as read locally. Returns count updated.
function Cache:markAllRead(mode, opts)
    opts = opts or {}
    local list_mode = mode
    if mode == "all" or mode == "unread" then
        list_mode = "unread"
    end
    local items = self:listByMode(list_mode, opts)
    local count = 0
    for _, item in ipairs(items) do
        if item.unread then
            local article = self:getArticle(item.id)
            if article and article.unread then
                article.unread = false
                self:putArticle(article)
                count = count + 1
            end
        end
    end
    return count
end

function Cache:setMeta(meta)
    self.index._meta = meta or {}
    self:saveIndex()
end

function Cache:getMeta()
    return self.index._meta or {}
end

function Cache:queue(action)
    local queue = self.index._queue or {}
    for index, existing in ipairs(queue) do
        if tostring(existing.id) == tostring(action.id) and existing.action == action.action then
            queue[index] = action
            self.index._queue = queue
            self:saveIndex()
            return
        end
    end
    table.insert(queue, action)
    self.index._queue = queue
    self:saveIndex()
end

function Cache:dequeue()
    local queue = self.index._queue or {}
    local action = table.remove(queue, 1)
    self.index._queue = queue
    self:saveIndex()
    return action
end

function Cache:queuedActions()
    return self.index._queue or {}
end

function Cache:clearQueue()
    local n = #(self.index._queue or {})
    self.index._queue = {}
    self:saveIndex()
    return n
end

Cache.SETTING_MAX_RETAINED = "freshrss_cache_max_articles"
Cache.RETAIN_CAPS = { 500, 1000, 2000, 5000 }
Cache.DEFAULT_MAX_RETAINED = 1000

local function cycleCap(current, caps, default)
    current = tonumber(current) or default
    for i, cap in ipairs(caps) do
        if cap == current and caps[i + 1] then
            return caps[i + 1]
        elseif cap == current then
            return caps[1]
        elseif current < cap then
            return cap
        end
    end
    return caps[1] or default
end

local function clampToCaps(value, caps, default)
    value = tonumber(value) or default
    for _, cap in ipairs(caps) do
        if cap == value then return value end
    end
    local best, best_dist = default, math.huge
    for _, cap in ipairs(caps) do
        local d = math.abs(cap - value)
        if d < best_dist then
            best, best_dist = cap, d
        end
    end
    return best
end

function Cache.readMaxRetained(settings)
    settings = settings or (rawget(_G, "G_reader_settings"))
    local raw = settings and settings.readSetting and settings:readSetting(Cache.SETTING_MAX_RETAINED)
    return clampToCaps(raw, Cache.RETAIN_CAPS, Cache.DEFAULT_MAX_RETAINED)
end

function Cache.cycleMaxRetained(settings)
    settings = settings or G_reader_settings
    local next_cap = cycleCap(Cache.readMaxRetained(settings), Cache.RETAIN_CAPS, Cache.DEFAULT_MAX_RETAINED)
    settings:saveSetting(Cache.SETTING_MAX_RETAINED, next_cap)
    settings:flush()
    return next_cap
end

function Cache:articleCount()
    local n = 0
    for key, item in pairs(self.index) do
        if key ~= "_queue" and key ~= "_meta" and type(item) == "table" and item.id then
            n = n + 1
        end
    end
    return n
end

---Delete one article JSON + index entry. Returns true if removed.
---Pinned favorites (favorites/ copy or starred) are never deleted.
function Cache:deleteArticle(id)
    id = tostring(id or "")
    if id == "" then return false end
    local item = self.index[id]
    if (item and item.starred) or self:isPinnedFavorite(id) then
        return false
    end
    local path = self:path(id)
    os.remove(path)
    if self.index[id] then
        self.index[id] = nil
        self:saveIndex()
        return true
    end
    return false
end

---Prune oldest non-starred articles until count <= max_retain.
---@return number evicted
function Cache:evictOldest(max_retain)
    max_retain = tonumber(max_retain) or Cache.DEFAULT_MAX_RETAINED
    if max_retain < 1 then max_retain = 1 end
    local items = {}
    for key, item in pairs(self.index) do
        if key ~= "_queue" and key ~= "_meta" and type(item) == "table" and item.id then
            table.insert(items, item)
        end
    end
    if #items <= max_retain then return 0 end

    table.sort(items, function(a, b)
        return tostring(a.updated or "") < tostring(b.updated or "")
    end)

    local evicted = 0
    local count = #items
    for _, item in ipairs(items) do
        if count <= max_retain then break end
        if item.starred or self:isPinnedFavorite(item.id) then
            -- Never delete starred / permanently pinned favorites.
        else
            if self:deleteArticle(item.id) then
                evicted = evicted + 1
                count = count - 1
            end
        end
    end
    return evicted
end

---Ensure favorites/ copies appear in the index (e.g. after reinstall / partial wipe).
function Cache:loadPinnedFavorites()
    local dir = self:favoritesDir()
    if lfs.attributes(dir, "mode") ~= "directory" then return 0 end
    local loaded = 0
    for name in lfs.dir(dir) do
        if name:match("%.json$") then
            local path = dir .. "/" .. name
            local file = io.open(path, "r")
            if file then
                local ok, article = pcall(json.decode, file:read("*a"))
                file:close()
                if ok and type(article) == "table" and article.id then
                    article.starred = true
                    article.pinned = true
                    -- Refresh main cache copy without clearing the pin.
                    local id = tostring(article.id)
                    local main = assert(io.open(self:path(id), "w"))
                    main:write(json.encode(article))
                    main:close()
                    self.index[id] = self:indexEntryFromArticle(article)
                    self.index[id].starred = true
                    self.index[id].pinned = true
                    loaded = loaded + 1
                end
            end
        end
    end
    if loaded > 0 then self:saveIndex() end
    return loaded
end

local function dirSizeBytes(path)
    local total = 0
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok or not iter then return 0 end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." then
            local full = path .. "/" .. name
            local attr = lfs.attributes(full)
            if attr and attr.mode == "file" then
                total = total + (attr.size or 0)
            elseif attr and attr.mode == "directory" then
                total = total + dirSizeBytes(full)
            end
        end
    end
    return total
end

---Approximate on-disk size of cache root (articles + images), in bytes.
function Cache:approxSizeBytes()
    return dirSizeBytes(self.root)
end

function Cache.formatSize(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 then return string.format("%d B", bytes) end
    if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
    return string.format("%.1f MB", bytes / (1024 * 1024))
end

return Cache
