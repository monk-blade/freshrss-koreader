package.path = "./freshrss.koplugin/?.lua;./?.lua;" .. package.path

local ListFormat = dofile("./freshrss.koplugin/list_format.lua")

describe("FreshRSS list_format helpers", function()
    it("normalizes millisecond timestamps", function()
        assert.equals(1700000000, ListFormat.toEpochSeconds(1700000000))
        assert.equals(1700000000, ListFormat.toEpochSeconds(1700000000000))
        assert.is_nil(ListFormat.toEpochSeconds(nil))
        assert.is_nil(ListFormat.toEpochSeconds(0))
    end)

    it("formats short article dates", function()
        local noon = os.time({ year = 2026, month = 7, day = 12, hour = 12, min = 0, sec = 0 })
        local earlier = os.time({ year = 2026, month = 7, day = 12, hour = 9, min = 5, sec = 0 })
        local other_day = os.time({ year = 2026, month = 3, day = 4, hour = 10, min = 0, sec = 0 })
        local other_year = os.time({ year = 2024, month = 12, day = 25, hour = 10, min = 0, sec = 0 })
        assert.equals(os.date("%H:%M", earlier), ListFormat.formatArticleDate(earlier, noon))
        assert.equals(os.date("%b %d", other_day), ListFormat.formatArticleDate(other_day, noon))
        assert.equals("2024-12-25", ListFormat.formatArticleDate(other_year, noon))
    end)

    it("builds row mandatory as feed · post time", function()
        local ts = os.time({ year = 2026, month = 7, day = 11, hour = 8, min = 0, sec = 0 })
        local now = os.time({ year = 2026, month = 7, day = 12, hour = 12, min = 0, sec = 0 })
        local date = ListFormat.formatArticleDate(ts, now)
        assert.equals("Hacker News · " .. date, ListFormat.rowMandatory({
            updated = ts,
            feed_title = "Hacker News",
        }, now))
        local today_ts = os.time({ year = 2026, month = 7, day = 12, hour = 9, min = 5, sec = 0 })
        assert.equals("Feed · " .. os.date("%H:%M", today_ts), ListFormat.rowMandatory({
            updated = today_ts,
            feed_title = "Feed",
        }, now))
        assert.equals("Solo Feed", ListFormat.rowMandatory({ feed_title = "Solo Feed" }, now))
        assert.equals(date, ListFormat.rowMandatory({ updated = ts }, now))
        -- published-only and string timestamps still format
        assert.equals("News · " .. date, ListFormat.rowMandatory({
            published = tostring(ts),
            feed_title = "News",
        }, now))
    end)

    it("builds two-line row text with title then feed · time", function()
        local ts = os.time({ year = 2026, month = 7, day = 12, hour = 9, min = 5, sec = 0 })
        local now = os.time({ year = 2026, month = 7, day = 12, hour = 12, min = 0, sec = 0 })
        local text = ListFormat.rowText({
            title = "Hello",
            unread = true,
            starred = true,
            feed_title = "Feed",
            updated = ts,
        }, { now = now })
        assert.equals("● ★ Hello\nFeed · " .. os.date("%H:%M", ts), text)
        local read = ListFormat.rowText({
            title = "Done",
            unread = false,
            feed_title = "Feed",
        }, { now = now })
        assert.equals("○ Done\nFeed", read)
    end)

    it("looks up unread counts by stream id", function()
        local meta = {
            unreadcounts = {
                { id = "feed/http://a", count = 3 },
                { id = "feed/http://b", count = 0 },
            },
        }
        assert.equals(3, ListFormat.unreadCountForStream(meta, "feed/http://a"))
        assert.equals(0, ListFormat.unreadCountForStream(meta, "feed/http://b"))
        assert.is_nil(ListFormat.unreadCountForStream(meta, "feed/missing"))
        assert.is_nil(ListFormat.unreadCountForStream(nil, "feed/http://a"))
    end)
end)
