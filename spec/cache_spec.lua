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

    it("sorts newest or oldest and hides feeds from All/Unread", function()
        cache:putArticle({ id = "1", title = "A", unread = true, feed_id = "feed/1", updated = 3 })
        cache:putArticle({ id = "2", title = "B", unread = true, feed_id = "feed/2", updated = 1 })
        cache:putArticle({ id = "3", title = "C", unread = true, feed_id = "feed/1", updated = 2 })
        local newest = cache:listByMode("unread", { sort = Cache.SORT_NEWEST })
        assert.equals("1", newest[1].id)
        local oldest = cache:listByMode("unread", { sort = Cache.SORT_OLDEST })
        assert.equals("2", oldest[1].id)

        local stored = {}
        local settings = {
            readSetting = function(_, key) return stored[key] end,
            saveSetting = function(_, key, value) stored[key] = value end,
            flush = function() end,
        }
        assert.is_true(Cache.toggleHiddenFeed(settings, "feed/1"))
        local hidden = Cache.readHiddenFeeds(settings)
        assert.is_true(hidden["feed/1"])
        local filtered = cache:listByMode("unread", {
            sort = Cache.SORT_NEWEST,
            hidden_feeds = hidden,
            apply_hidden = true,
        })
        assert.equals(1, #filtered)
        assert.equals("2", filtered[1].id)
        -- Feed browse still lists hidden feed articles when not applying hide.
        assert.equals(2, #cache:listByMode("feed", { feed_id = "feed/1", apply_hidden = false }))
        assert.is_false(Cache.toggleHiddenFeed(settings, "feed/1"))
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
                    { id = "user/-/label/News", count = 4 },
                },
            },
        })
        assert.equals(12, cache:unreadCountForStream("feed/http://news"))
        assert.equals(0, cache:unreadCountForStream("feed/http://empty"))
        assert.is_nil(cache:unreadCountForStream("feed/missing"))
        assert.equals(4, cache:unreadCountForBrowse({ mode = "label", label = "user/-/label/News" }))
        assert.equals(12, cache:unreadCountForBrowse({ mode = "feed", feed_id = "feed/http://news" }))
    end)

    it("falls back to local unread for browse when stream meta is missing", function()
        cache:putArticle({
            id = "1", title = "A", unread = true, feed_id = "feed/1",
            labels = { "user/-/label/Ed" }, updated = 3,
        })
        cache:putArticle({
            id = "2", title = "B", unread = true, feed_id = "feed/2",
            labels = { "user/-/label/Ed" }, updated = 2,
        })
        cache:putArticle({
            id = "3", title = "C", unread = false, feed_id = "feed/1",
            labels = { "user/-/label/Ed" }, updated = 1,
        })
        cache:putArticle({
            id = "4", title = "D", unread = true, feed_id = "feed/9",
            labels = {}, updated = 4, starred = true,
        })
        assert.equals(3, cache:unreadCount())
        assert.equals(2, cache:unreadCountForBrowse({ mode = "label", label = "user/-/label/Ed" }))
        assert.equals(1, cache:unreadCountForBrowse({ mode = "feed", feed_id = "feed/1" }))
        assert.equals(1, cache:unreadCountForBrowse({ mode = "starred" }))
        assert.equals(3, cache:unreadCountForBrowse({ mode = "unread" }))
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

    it("pins favorites permanently and unpins on unstar", function()
        cache:putArticle({
            id = "fav-1",
            title = "Pinned",
            html = "<p>keep</p>",
            unread = false,
            starred = true,
            updated = 10,
        })
        assert.is_true(cache:isPinnedFavorite("fav-1"))
        local pin = io.open(cache:favoritePath("fav-1"), "r")
        assert.truthy(pin)
        pin:close()

        -- Survive deletion of the main cache file via getArticle fallback.
        os.remove(cache:path("fav-1"))
        local from_pin = cache:getArticle("fav-1")
        assert.equals("Pinned", from_pin.title)
        assert.is_true(from_pin.starred)

        -- Eviction must not remove pinned favorites.
        for i = 1, 4 do
            cache:putArticle({
                id = "n" .. i,
                title = "N" .. i,
                unread = false,
                starred = false,
                updated = i,
            })
        end
        cache:evictOldest(1)
        assert.truthy(cache:isPinnedFavorite("fav-1"))
        assert.truthy(cache:getArticle("fav-1"))
        assert.is_false(cache:deleteArticle("fav-1"))

        -- Unstar removes the permanent copy.
        local art = cache:getArticle("fav-1")
        art.starred = false
        cache:putArticle(art)
        assert.is_false(cache:isPinnedFavorite("fav-1"))
    end)

    it("reloads pinned favorites into a wiped index", function()
        cache:putArticle({
            id = "keep-me",
            title = "Forever",
            html = "<p>x</p>",
            unread = false,
            starred = true,
            updated = 99,
        })
        assert.is_true(cache:isPinnedFavorite("keep-me"))
        -- Wipe index as if it was lost; favorites/ file remains.
        cache.index = {}
        cache:saveIndex()
        local loaded = cache:loadPinnedFavorites()
        assert.equals(1, loaded)
        assert.equals("Forever", cache.index["keep-me"].title)
        assert.is_true(cache.index["keep-me"].starred)
        assert.is_true(cache.index["keep-me"].pinned)
    end)

    it("backfills missing index dates from article JSON", function()
        local id = "dated-1"
        local file = assert(io.open(cache:path(id), "w"))
        file:write(helpers.encode({
            id = id,
            title = "T",
            feed_title = "Feed",
            published = 1700000000,
            unread = true,
        }))
        file:close()
        cache.index[id] = { id = id, title = "T", feed_title = "Feed", unread = true }
        local n = cache:backfillIndexDates()
        assert.is_true(n >= 1)
        assert.equals(1700000000, tonumber(cache.index[id].updated))
        local ListFormat = dofile("./freshrss.koplugin/list_format.lua")
        local mandatory = ListFormat.rowMandatory(cache.index[id])
        assert.truthy(mandatory:find("Feed", 1, true))
        assert.truthy(mandatory:find("·", 1, true))
    end)

    it("indexes published when updated is missing", function()
        cache:putArticle({
            id = "pub-only",
            title = "P",
            feed_title = "Sandesh",
            published = 1700000000,
            unread = true,
        })
        assert.equals(1700000000, tonumber(cache.index["pub-only"].updated))
        local ListFormat = dofile("./freshrss.koplugin/list_format.lua")
        assert.equals(
            "Sandesh · " .. ListFormat.formatArticleDate(1700000000),
            ListFormat.rowMandatory(cache.index["pub-only"])
        )
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
