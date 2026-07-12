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
            streamItemIds = function()
                return { ids = { "tag:google.com,2005:reader/item/1" } }
            end,
            streamItemContents = function(_, ids)
                assert.same({ "tag:google.com,2005:reader/item/1" }, ids)
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
            streamItemIds = function() return { ids = {} } end,
            streamItemContents = function() return { items = {} } end,
        }
        local ok = sync:refresh(api, nil, function(stage, ratio)
            table.insert(stages, stage)
        end)
        assert.is_true(ok)
        assert.equals("login", stages[1])
        assert.equals("queue", stages[2])
        assert.equals("meta", stages[3])
        local seen = {}
        for _, stage in ipairs(stages) do seen[stage] = true end
        assert.is_true(seen.stream)
        assert.is_true(seen.cache)
        assert.is_true(seen.done)
        assert.equals("done", stages[#stages])
    end)

    it("flushes the pending queue before fetching the stream", function()
        local order = {}
        local queue = {
            { id = "q1", action = "read", state = true },
        }
        local cache = {
            getArticle = function() return nil end,
            putArticle = function() end,
            queuedActions = function() return queue end,
            dequeue = function()
                table.insert(order, "dequeue")
                return table.remove(queue, 1)
            end,
            queue = function(_, action)
                table.insert(queue, action)
            end,
            setMeta = function() end,
        }
        local settings = { saveSetting = function() end, flush = function() end, readSetting = function() end }
        local sync = Sync:new(cache, settings)
        local api = {
            login = function() return true end,
            listSubscriptions = function() return {} end,
            listTags = function() return {} end,
            unreadCount = function() return {} end,
            editTag = function()
                table.insert(order, "editTag")
                return true
            end,
            editTagMany = function()
                table.insert(order, "editTagMany")
                return true
            end,
            streamItemIds = function()
                table.insert(order, "streamItemIds")
                return { ids = {} }
            end,
            streamItemContents = function()
                table.insert(order, "streamItemContents")
                return { items = {} }
            end,
            stream = function()
                table.insert(order, "stream")
                return { items = {} }
            end,
        }
        local ok, result = sync:refresh(api)
        assert.is_true(ok)
        assert.equals("dequeue", order[1])
        assert.equals("editTagMany", order[2])
        assert.equals("streamItemIds", order[3])
        assert.equals(1, result.flushed)
        assert.equals(0, result.flush_failed)
    end)

    it("paginates stream ids and fetches contents only for cache misses", function()
        local stored = 0
        local id_calls = {}
        local content_calls = {}
        -- Pre-seed cache for ids 1..30 so only 31..50 are fetched.
        local articles = {}
        for i = 1, 30 do
            articles[tostring(i)] = { id = tostring(i), html = "cached" }
        end
        local cache = {
            getArticle = function(_, id) return articles[tostring(id)] end,
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
        local api = {
            login = function() return true end,
            listSubscriptions = function() return {} end,
            listTags = function() return {} end,
            unreadCount = function() return {} end,
            streamItemIds = function(_, stream_id, opts)
                page = page + 1
                table.insert(id_calls, opts)
                local ids = {}
                if page == 1 then
                    for i = 1, 30 do table.insert(ids, tostring(i)) end
                    return { continuation = "cont-2", ids = ids }
                end
                for i = 31, 50 do table.insert(ids, tostring(i)) end
                return { ids = ids }
            end,
            streamItemContents = function(_, ids)
                table.insert(content_calls, ids)
                local items = {}
                for _, id in ipairs(ids) do
                    table.insert(items, { id = id, title = "A" .. id, categories = {} })
                end
                return { items = items }
            end,
        }
        local ok, result = sync:refresh(api)
        assert.is_true(ok)
        assert.equals(20, stored)
        assert.equals(20, result.fetched)
        assert.is_true(result.exclude_read)
        assert.equals(2, #id_calls)
        assert.is_true(id_calls[1].exclude_read)
        assert.equals("cont-2", id_calls[2].continuation)
        assert.equals(20, id_calls[2].n)
        assert.equals(1, #content_calls)
        assert.equals(20, #content_calls[1])
    end)

    it("batches queue flush by action and state", function()
        local queue = {
            { id = "1", action = "read", state = true },
            { id = "2", action = "read", state = true },
            { id = "3", action = "starred", state = true },
            { id = "4", action = "read", state = false },
        }
        local batches = {}
        local cache = {
            queuedActions = function() return queue end,
            dequeue = function() return table.remove(queue, 1) end,
            queue = function(_, action) table.insert(queue, action) end,
        }
        local sync = Sync:new(cache, {})
        local api = {
            login = function() return true end,
            editTagMany = function(_, ids, action, state)
                table.insert(batches, { ids = ids, action = action, state = state })
                return true
            end,
            invalidateSession = function() end,
        }
        local stats = sync:flushQueue(api)
        assert.equals(4, stats.flushed)
        assert.equals(0, stats.failed)
        assert.equals(3, #batches)
        assert.same({ "1", "2" }, batches[1].ids)
        assert.equals("read", batches[1].action)
        assert.is_true(batches[1].state)
        assert.same({ "3" }, batches[2].ids)
        assert.equals("starred", batches[2].action)
        assert.same({ "4" }, batches[3].ids)
        assert.is_false(batches[3].state)
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

    it("resolves sync scope to current view or always reading-list", function()
        local stored = { freshrss_sync_scope = "current_view" }
        local settings = {
            readSetting = function(_, key) return stored[key] end,
            saveSetting = function(_, key, value) stored[key] = value end,
            flush = function() end,
        }
        local sync = Sync:new({}, settings)
        assert.equals("feed/9", sync:resolveStreamId({ mode = "feed", feed_id = "feed/9" }))
        assert.equals(Sync.SCOPE_READING_LIST, Sync.cycleSyncScope(settings))
        assert.equals(Sync.READING_LIST, sync:resolveStreamId({ mode = "feed", feed_id = "feed/9" }))
        assert.equals("Reading list", Sync.streamLabel({ mode = "unread" }, Sync.READING_LIST))
        assert.equals("Starred", Sync.streamLabel({ mode = "starred" }, Sync.STARRED))
        assert.equals("News", Sync.streamLabel({ mode = "label", label = "user/-/label/News" }, "user/-/label/News"))
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

    it("falls back updated from published or crawlTimeMsec", function()
        local from_published = Sync._articleFromRaw({
            id = "1",
            title = "A",
            published = 1700000000,
            categories = {},
        })
        assert.equals(1700000000, from_published.updated)
        assert.equals(1700000000, from_published.published)
        local from_crawl = Sync._articleFromRaw({
            id = "2",
            title = "B",
            crawlTimeMsec = 1700000000000,
            categories = {},
        })
        assert.equals(1700000000, from_crawl.updated)
    end)

    it("prefetchImages uses Images.downloadMany with a job list", function()
        local many_calls = {}
        local Images = {
            MAX_PARALLEL = 3,
            ensureDirectory = function(dir) return dir end,
            directory = function(root) return root .. "/images" end,
            extractImageUrls = function(html)
                if html:find("one") then return { "https://cdn/a.png" } end
                if html:find("two") then return { "https://cdn/b.png", "https://cdn/a.png" } end
                return {}
            end,
            normalizeUrl = function(url) return url end,
            findCachedFilename = function() return nil end,
            filenameForUrl = function(url)
                return url:match("([^/]+)$")
            end,
            downloadMany = function(jobs, opts)
                table.insert(many_calls, { jobs = jobs, opts = opts })
                return {}, 2
            end,
        }
        local settings = {
            readSetting = function(_, key)
                if key == "freshrss_viewer_show_images" then return true end
                return nil
            end,
        }
        local sync = Sync:new({ root = "/tmp/freshrss-cache" }, settings)
        sync.images = Images
        local stats = sync:prefetchImages({
            { summary = { content = "<img one>" } },
            { content = { content = "<img two>" } },
        })
        assert.equals(2, stats.downloaded)
        assert.equals(1, #many_calls)
        assert.equals(2, #many_calls[1].jobs)
        assert.equals("https://cdn/a.png", many_calls[1].jobs[1].url)
        assert.equals("https://cdn/b.png", many_calls[1].jobs[2].url)
        assert.equals(3, many_calls[1].opts.max_parallel)
    end)
end)
