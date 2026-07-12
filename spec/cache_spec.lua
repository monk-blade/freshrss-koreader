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
end)
