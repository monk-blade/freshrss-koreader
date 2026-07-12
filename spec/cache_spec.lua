package.path = "./freshrss.koplugin/?.lua;./?.lua;" .. package.path
local helpers = dofile("./spec/helpers.lua")
helpers.install_json()
helpers.install_lfs()
local Cache = dofile("./freshrss.koplugin/cache.lua")

describe("FreshRSS cache", function()
    local cache

    before_each(function()
        local path = os.tmpname()
        os.remove(path)
        cache = Cache:new(path)
    end)

    it("stores and retrieves article IDs as strings", function()
        cache:putArticle({ id = "1234567890123456", title = "Test", unread = true, updated = 2 })
        local article = cache:getArticle("1234567890123456")
        assert.equals("1234567890123456", article.id)
        assert.equals(1, cache:unreadCount())
    end)

    it("queues offline actions", function()
        cache:queue({ id = "a", action = "read", state = true })
        assert.equals("a", cache:dequeue().id)
        assert.equals(0, #cache:queuedActions())
    end)

    it("does not treat the offline queue as an article", function()
        cache:putArticle({ id = "art-1", title = "Hello", unread = true, updated = 1 })
        cache:queue({ id = "art-1", action = "read", state = true })
        local articles = cache:listArticles()
        assert.equals(1, #articles)
        assert.equals("art-1", articles[1].id)
        assert.equals(1, cache:unreadCount())
    end)

    it("filters by browse mode and marks all read locally", function()
        cache:putArticle({ id = "1", title = "A", unread = true, starred = true, feed_id = "feed/1", updated = 3, labels = { "user/-/label/News" } })
        cache:putArticle({ id = "2", title = "B", unread = true, starred = false, feed_id = "feed/2", updated = 2 })
        cache:putArticle({ id = "3", title = "C", unread = false, starred = true, feed_id = "feed/1", updated = 1 })
        assert.equals(2, #cache:listByMode("unread"))
        assert.equals(2, #cache:listByMode("starred"))
        assert.equals(2, #cache:listByMode("feed", { feed_id = "feed/1" }))
        assert.equals(1, #cache:listByMode("label", { label = "user/-/label/News" }))
        local marked = cache:markAllRead("unread")
        assert.equals(2, marked)
        assert.equals(0, cache:unreadCount())
    end)

    it("clears the offline queue", function()
        cache:queue({ id = "a", action = "read", state = true })
        cache:queue({ id = "b", action = "starred", state = true })
        assert.equals(2, cache:clearQueue())
        assert.equals(0, #cache:queuedActions())
    end)

    it("reads per-stream unread counts from sync meta", function()
        cache:setMeta({
            counts = {
                unreadcounts = {
                    { id = "feed/http://news", count = 12 },
                    { id = "feed/http://empty", count = 0 },
                },
            },
        })
        assert.equals(12, cache:unreadCountForStream("feed/http://news"))
        assert.equals(0, cache:unreadCountForStream("feed/http://empty"))
        assert.is_nil(cache:unreadCountForStream("feed/missing"))
    end)

    it("evicts oldest non-starred articles and keeps starred", function()
        for i = 1, 5 do
            cache:putArticle({
                id = tostring(i),
                title = "A" .. i,
                unread = false,
                starred = (i == 1),
                updated = i,
            })
        end
        assert.equals(5, cache:articleCount())
        local evicted = cache:evictOldest(2)
        assert.equals(3, evicted)
        assert.equals(2, cache:articleCount())
        assert.truthy(cache:getArticle("1")) -- starred kept
        assert.truthy(cache:getArticle("5")) -- newest non-starred kept
        assert.is_nil(cache:getArticle("2"))
    end)

    it("cycles retain caps", function()
        local store = {}
        local settings = {
            readSetting = function(_, k) return store[k] end,
            saveSetting = function(_, k, v) store[k] = v end,
            flush = function() end,
        }
        assert.equals(1000, Cache.readMaxRetained(settings))
        assert.equals(2000, Cache.cycleMaxRetained(settings))
        assert.equals(2000, Cache.readMaxRetained(settings))
    end)
end)
