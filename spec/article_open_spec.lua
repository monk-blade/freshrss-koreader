package.path = "./freshrss.koplugin/?.lua;./?.lua;" .. package.path

-- Keep in sync with Plugin.ARTICLE_OPEN_DEFER_* in freshrss.koplugin/main.lua.
-- Image apply/download must be scheduleIn-deferred and cancelable. Mark-read on
-- open must never call applyAction (15s socket block hangs Kindle second-open).
local ARTICLE_OPEN_DEFER = {
    cached_images = 0.25,
    download = 0.75,
    images_retry = 1.0,
}

local function read_main()
    return assert(io.open("./freshrss.koplugin/main.lua", "r")):read("*a")
end

local function open_article_body(main_src)
    local open_start = main_src:find("function Plugin:openArticle", 1, true)
    assert.truthy(open_start)
    return main_src:sub(open_start, open_start + 14000)
end

describe("FreshRSS article open deferral (Kindle-safe)", function()
    it("stages cached images before network download", function()
        assert.is_true(ARTICLE_OPEN_DEFER.cached_images > 0)
        assert.is_true(ARTICLE_OPEN_DEFER.download > ARTICLE_OPEN_DEFER.cached_images)
        assert.is_true(ARTICLE_OPEN_DEFER.images_retry > 0)
    end)

    it("keeps API block timeout documented as the hang match", function()
        -- socketutil:set_timeout(15, 30) in api.lua — exact gap in Paperwhite logs.
        local api_src = assert(io.open("./freshrss.koplugin/api.lua", "r")):read("*a")
        assert.truthy(api_src:find("set_timeout%(15,%s*30%)", 1, false))
    end)

    it("does not call applyAction inside openArticle (mark-read is queue-only)", function()
        local main_src = read_main()
        local open_body = open_article_body(main_src)
        assert.truthy(open_body:find("forceRePaint", 1, true))
        assert.truthy(open_body:find("ARTICLE_OPEN_DEFER_CACHED_IMAGES", 1, true))
        assert.truthy(open_body:find("ARTICLE_OPEN_DEFER_DOWNLOAD", 1, true))

        local show_at = open_body:find("UIManager:show(widget", 1, true)
        assert.truthy(show_at)
        local before_show = open_body:sub(1, show_at - 1)
        local after_show = open_body:sub(show_at)

        -- Text-first: no cachedMap before show on any open (including warm cache).
        assert.is_nil(before_show:find("Images.cachedMap", 1, true))
        assert.is_nil(before_show:find("applyImageMap", 1, true))

        -- Mark-read on open: local putArticle + queueAction only — never applyAction.
        local mark_at = before_show:find("if mark_on_open then", 1, true)
        assert.truthy(mark_at)
        local mark_chunk = before_show:sub(mark_at, mark_at + 350)
        assert.truthy(mark_chunk:find("queueAction", 1, true))
        assert.truthy(mark_chunk:find("putArticle", 1, true))
        assert.is_nil(mark_chunk:find("applyAction", 1, true))

        -- No deferred HTTP mark-read after show (that was the second-open hang).
        assert.is_nil(after_show:find("self.sync:applyAction", 1, true))
        assert.is_nil(after_show:find("self.sync:queueAction", 1, true))
        assert.is_nil(main_src:find("ARTICLE_OPEN_DEFER_MARK_READ", 1, true))
    end)

    it("cancels scheduled open stages via unschedule on close and reopen", function()
        local main_src = read_main()
        assert.truthy(main_src:find("function Plugin:cancelArticleOpenTasks", 1, true))
        assert.truthy(main_src:find("UIManager:unschedule", 1, true))
        assert.truthy(main_src:find("function Plugin:_scheduleArticleOpenTask", 1, true))

        local open_body = open_article_body(main_src)
        -- New open always cancels leftover timers from the previous viewer.
        assert.truthy(open_body:find("cancelArticleOpenTasks", 1, true))
        -- Viewer detach / close cancels so Stage 1–2 cannot hit a dead widget.
        assert.truthy(open_body:find("on_detach = function()", 1, true))
        local detach_at = open_body:find("on_detach = function()", 1, true)
        local detach_chunk = open_body:sub(detach_at, detach_at + 250)
        assert.truthy(detach_chunk:find("cancelArticleOpenTasks", 1, true))

        -- Staged work goes through the tracked scheduler, not bare scheduleIn.
        assert.truthy(open_body:find("_scheduleArticleOpenTask(Plugin.ARTICLE_OPEN_DEFER_CACHED_IMAGES", 1, true))
        assert.truthy(open_body:find("_scheduleArticleOpenTask(Plugin.ARTICLE_OPEN_DEFER_DOWNLOAD", 1, true))
        assert.is_nil(open_body:find("UIManager:scheduleIn(Plugin.ARTICLE_OPEN_DEFER_", 1, true))
    end)

    it("guards deferred callbacks with viewer identity and _closing", function()
        local open_body = open_article_body(read_main())
        local show_at = open_body:find("UIManager:show(widget", 1, true)
        assert.truthy(show_at)
        local after_show = open_body:sub(show_at)
        assert.truthy(after_show:find("self.viewer ~= widget", 1, true))
        assert.truthy(after_show:find("widget._closing", 1, true))
    end)
end)
