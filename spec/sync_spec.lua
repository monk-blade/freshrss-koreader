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
        local settings = { saveSetting = function() end, flush = function() end, readSetting = function() end }
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

    it("reports sync progress stages in order", function()
        local stages = {}
        local cache = {
            getArticle = function() return nil end,
            putArticle = function() end,
            queuedActions = function() return {} end,
        }
        local settings = { saveSetting = function() end, flush = function() end, readSetting = function() end }
        local sync = Sync:new(cache, settings)
        local api = {
            login = function() return true end,
            listSubscriptions = function() return {} end,
            listTags = function() return {} end,
            unreadCount = function() return {} end,
            stream = function() return { items = {} } end,
        }
        local ok = sync:refresh(api, nil, function(stage, ratio)
            table.insert(stages, stage)
        end)
        assert.is_true(ok)
        assert.equals("login", stages[1])
        assert.equals("meta", stages[2])
        local seen = {}
        for _, stage in ipairs(stages) do seen[stage] = true end
        assert.is_true(seen.stream)
        assert.is_true(seen.cache)
        assert.is_true(seen.done)
        assert.equals("done", stages[#stages])
    end)

    it("paginates stream results using continuation until the article cap", function()
        local stored = 0
        local calls = {}
        local cache = {
            getArticle = function() return nil end,
            putArticle = function() stored = stored + 1 end,
            queuedActions = function() return {} end,
        }
        local settings = {
            saveSetting = function() end,
            flush = function() end,
            readSetting = function(_, key)
                if key == "freshrss_articles_per_sync" then return 50 end
                if key == "freshrss_sync_unread_only" then return true end
                return nil
            end,
        }
        local sync = Sync:new(cache, settings)
        local page = 0
        local function makeItems(start_id, count)
            local items = {}
            for i = 1, count do
                table.insert(items, { id = tostring(start_id + i - 1), title = "A" .. i, categories = {} })
            end
            return items
        end
        local api = {
            login = function() return true end,
            listSubscriptions = function() return {} end,
            listTags = function() return {} end,
            unreadCount = function() return {} end,
            stream = function(_, stream_id, opts)
                page = page + 1
                table.insert(calls, opts)
                if page == 1 then
                    return { continuation = "cont-2", items = makeItems(1, 30) }
                end
                return { items = makeItems(31, 30) }
            end,
        }
        local ok, result = sync:refresh(api)
        assert.is_true(ok)
        assert.equals(50, stored)
        assert.equals(50, result.fetched)
        assert.is_true(result.exclude_read)
        assert.equals(2, #calls)
        assert.is_true(calls[1].exclude_read)
        assert.equals("cont-2", calls[2].continuation)
        assert.equals(20, calls[2].n)
    end)

    it("defaults to unread-only sync when the setting is unset", function()
        local settings = { readSetting = function() return nil end }
        local sync = Sync:new({}, settings)
        local opts = sync:syncOptions()
        assert.is_true(opts.exclude_read)
        assert.equals(100, opts.max_articles)
    end)

    it("maps browse modes to stream ids", function()
        local sync = Sync:new({}, { readSetting = function() return nil end })
        assert.equals("user/-/state/com.google/reading-list", sync:streamIdForBrowse({ mode = "unread" }))
        assert.equals("user/-/state/com.google/starred", sync:streamIdForBrowse({ mode = "starred" }))
        assert.equals("feed/9", sync:streamIdForBrowse({ mode = "feed", feed_id = "feed/9" }))
        assert.equals("user/-/label/News", sync:streamIdForBrowse({ mode = "label", label = "user/-/label/News" }))
    end)

    it("stores feed id and labels from the stream payload", function()
        local article = Sync._articleFromRaw({
            id = "1",
            title = "Tagged",
            origin = { title = "Feed", streamId = "feed/42" },
            categories = {
                { id = "user/-/state/com.google/reading-list" },
                { id = "user/-/label/News" },
            },
        })
        assert.equals("feed/42", article.feed_id)
        assert.same({ "user/-/label/News" }, article.labels)
    end)
end)
