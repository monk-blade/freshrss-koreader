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
    return o
end

function Cache:saveIndex()
    local file = assert(io.open(self.index_path, "w"))
    file:write(json.encode(self.index))
    file:close()
end

function Cache:path(id)
    return self.root .. "/" .. tostring(id):gsub("[^%w_-]", "_") .. ".json"
end

function Cache:putArticle(article)
    local id = tostring(article.id)
    local file = assert(io.open(self:path(id), "w"))
    file:write(json.encode(article))
    file:close()
    self.index[id] = {
        id = id,
        title = article.title,
        feed_title = article.feed_title,
        feed_id = article.feed_id,
        unread = article.unread,
        starred = article.starred,
        updated = article.updated,
        labels = article.labels,
    }
    self:saveIndex()
end

function Cache:getArticle(id)
    local file = io.open(self:path(id), "r")
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
function Cache:listByMode(mode, opts)
    opts = opts or {}
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
            if include then
                table.insert(result, item)
            end
        end
    end
    table.sort(result, function(a, b) return tostring(a.updated or "") > tostring(b.updated or "") end)
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

return Cache
