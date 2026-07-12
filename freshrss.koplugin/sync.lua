local Sync = {}
Sync.__index = Sync

local READ_STATE = "user/-/state/com.google/read"
local STARRED_STATE = "user/-/state/com.google/starred"

local function hasCategory(categories, state_id)
    if type(categories) ~= "table" then return false end
    for _, category in ipairs(categories) do
        local id = type(category) == "table" and category.id or category
        if id == state_id then return true end
    end
    return false
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
        url = raw.alternate and raw.alternate[1] and raw.alternate[1].href,
        published = raw.published,
        updated = raw.updated,
        html = raw.summary and raw.summary.content or raw.content and raw.content.content or "",
        unread = server_unread and (old.unread ~= false),
        starred = server_starred or old.starred == true,
    }
end

function Sync:new(cache, settings)
    return setmetatable({ cache = cache, settings = settings }, self)
end

function Sync:refresh(api, stream_id)
    local ok, err = api:login()
    if not ok then return false, err end
    local subscriptions = api:listSubscriptions()
    local tags = api:listTags()
    local counts = api:unreadCount()
    local stream = api:stream(stream_id)
    if not stream or not stream.items then return false, "FreshRSS returned no article stream" end
    for _, raw in ipairs(stream.items) do
        local id = tostring(raw.id or raw.crawlTimeMsec or "")
        if id ~= "" then
            local old = self.cache:getArticle(id) or {}
            self.cache:putArticle(articleFromRaw(raw, old))
        end
    end
    self.settings:saveSetting("last_sync", os.time()); self.settings:flush()
    self:flushQueue(api)
    return true, { subscriptions = subscriptions, tags = tags, counts = counts }
end

function Sync:refreshAsync(api, stream_id, callback)
    api:loginAsync(function(logged_in, login_error)
        if not logged_in then callback(false, login_error); return end
        local pending = 4
        local result = {}
        local failed
        local function finished(key, value, error_message)
            if error_message then failed = error_message end
            result[key] = value
            pending = pending - 1
            if pending > 0 then return end
            if failed or not result.stream or not result.stream.items then
                callback(false, failed or "FreshRSS returned no article stream")
                return
            end
            for _, raw in ipairs(result.stream.items) do
                local id = tostring(raw.id or raw.crawlTimeMsec or "")
                if id ~= "" then
                    local old = self.cache:getArticle(id) or {}
                    self.cache:putArticle(articleFromRaw(raw, old))
                end
            end
            self.settings:saveSetting("last_sync", os.time()); self.settings:flush()
            self:flushQueue(api)
            callback(true, result)
        end
        api:requestAsync("reader/api/0/subscription/list?output=json", nil, nil, function(v, e) finished("subscriptions", v, e) end)
        api:requestAsync("reader/api/0/tag/list?output=json", nil, nil, function(v, e) finished("tags", v, e) end)
        api:requestAsync("reader/api/0/unread-count?output=json", nil, nil, function(v, e) finished("counts", v, e) end)
        api:requestAsync("reader/api/0/stream/contents/" .. (stream_id or "user/-/state/com.google/reading-list") .. "?output=json&n=100&r=newest", nil, nil, function(v, e) finished("stream", v, e) end)
    end)
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
    while #self.cache:queuedActions() > 0 do
        local action = self.cache:dequeue()
        local ok, error_message = api:editTag(action.id, action.action, action.state)
        if not ok then
            api:invalidateSession()
            if not api:login() then
                self:queueAction(action.id, action.action, action.state)
                break
            end
            ok = api:editTag(action.id, action.action, action.state)
            if not ok then
                self:queueAction(action.id, action.action, action.state)
                break
            end
        end
    end
end

-- Exported for unit tests
Sync._articleFromRaw = articleFromRaw
Sync._hasCategory = hasCategory

return Sync
