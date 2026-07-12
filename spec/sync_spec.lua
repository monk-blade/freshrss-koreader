package.path = "./freshrss.koplugin/?.lua;" .. package.path
local Sync = dofile("./freshrss.koplugin/sync.lua")

describe("FreshRSS state synchronization", function()
    it("sends a starred action immediately when online", function()
        local calls = {}
        local queued = {}
        local cache = {
            queue = function(_, action) table.insert(queued, action) end,
            queuedActions = function() return {} end,
            dequeue = function() end,
        }
        local settings = { saveSetting = function() end, flush = function() end }
        local sync = Sync:new(cache, settings)
        local api = {
            login = function() return true end,
            editTag = function(_, id, action, state)
                table.insert(calls, { id = id, action = action, state = state })
                return true
            end,
        }
        local ok = sync:applyAction(api, "item-42", "starred", true)
        assert.is_true(ok)
        assert.same({ id = "item-42", action = "starred", state = true }, calls[1])
        assert.equals(0, #queued)
    end)

    it("queues starring when the server is unavailable", function()
        local queued = {}
        local cache = { queue = function(_, action) table.insert(queued, action) end }
        local sync = Sync:new(cache, {})
        local api = { login = function() return false, "offline" end }
        local ok = sync:applyAction(api, "item-42", "starred", true)
        assert.is_false(ok)
        assert.equals("item-42", queued[1].id)
        assert.equals("starred", queued[1].action)
        assert.is_true(queued[1].state)
    end)

    it("derives unread and starred from GReader categories", function()
        local unread = Sync._articleFromRaw({
            id = "1",
            title = "Unread",
            categories = {
                { id = "user/-/state/com.google/reading-list" },
            },
        })
        assert.is_true(unread.unread)
        assert.is_false(unread.starred)

        local read_starred = Sync._articleFromRaw({
            id = "2",
            title = "Read starred",
            categories = {
                { id = "user/-/state/com.google/reading-list" },
                { id = "user/-/state/com.google/read" },
                { id = "user/-/state/com.google/starred" },
            },
        })
        assert.is_false(read_starred.unread)
        assert.is_true(read_starred.starred)
    end)

    it("keeps a locally marked-read article read when the server is still unread", function()
        local article = Sync._articleFromRaw({
            id = "3",
            title = "Optimistic read",
            categories = {
                { id = "user/-/state/com.google/reading-list" },
            },
        }, { unread = false })
        assert.is_false(article.unread)
    end)

    it("stores categories-derived state during refresh", function()
        local stored = {}
        local cache = {
            getArticle = function() return nil end,
            putArticle = function(_, article) stored[article.id] = article end,
            queuedActions = function() return {} end,
        }
        local settings = { saveSetting = function() end, flush = function() end }
        local sync = Sync:new(cache, settings)
        local api = {
            login = function() return true end,
            listSubscriptions = function() return {} end,
            listTags = function() return {} end,
            unreadCount = function() return {} end,
            stream = function()
                return {
                    items = {
                        {
                            id = "tag:google.com,2005:reader/item/1",
                            title = "Hello",
                            categories = {
                                { id = "user/-/state/com.google/reading-list" },
                                { id = "user/-/state/com.google/starred" },
                            },
                            origin = { title = "Feed" },
                            summary = { content = "<p>Hi</p>" },
                            published = 1700000000,
                        },
                    },
                }
            end,
        }
        local ok = sync:refresh(api)
        assert.is_true(ok)
        local article = stored["tag:google.com,2005:reader/item/1"]
        assert.is_true(article.unread)
        assert.is_true(article.starred)
        assert.equals("Hello", article.title)
        assert.equals("Feed", article.feed_title)
    end)
end)
