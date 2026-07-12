local lfs = require("libs/libkoreader-lfs")
local json = require("json")

local Cache = {}
Cache.__index = Cache

function Cache:new(root)
    lfs.mkdir(root)
    local o = setmetatable({ root = root, index_path = root .. "/index.json", index = {} }, self)
    local file = io.open(o.index_path, "r")
    if file then local ok, data = pcall(json.decode, file:read("*a")); file:close(); if ok and type(data) == "table" then o.index = data end end
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
    local file = assert(io.open(self:path(id), "w")); file:write(json.encode(article)); file:close()
    self.index[id] = { id = id, title = article.title, feed_title = article.feed_title, unread = article.unread, starred = article.starred, updated = article.updated }
    self:saveIndex()
end

function Cache:getArticle(id)
    local file = io.open(self:path(id), "r")
    if not file then return nil end
    local ok, value = pcall(json.decode, file:read("*a")); file:close()
    return ok and value or nil
end

function Cache:listArticles(feed_id)
    local result = {}
    for key, item in pairs(self.index) do
        if key ~= "_queue" and type(item) == "table" and item.id then
            if not feed_id or item.feed_id == feed_id then
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
        if key ~= "_queue" and type(item) == "table" and item.id and item.unread then
            count = count + 1
        end
    end
    return count
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
    local queue = self.index._queue or {}; local action = table.remove(queue, 1); self.index._queue = queue; self:saveIndex(); return action
end

function Cache:queuedActions()
    return self.index._queue or {}
end

return Cache
