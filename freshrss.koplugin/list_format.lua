-- Helpers for denser article-list rows (feed · post time mandatory text).
local ListFormat = {}

---Normalize GReader/FreshRSS timestamps (seconds or milliseconds) to epoch seconds.
function ListFormat.toEpochSeconds(ts)
    if ts == nil or ts == "" then return nil end
    local n = tonumber(ts)
    if not n or n <= 0 then return nil end
    -- Milliseconds (common in some GReader payloads)
    if n > 1e12 then
        n = math.floor(n / 1000)
    end
    return n
end

---Short published/updated label for Menu mandatory column.
function ListFormat.formatArticleDate(ts, now)
    local n = ListFormat.toEpochSeconds(ts)
    if not n then return nil end
    now = now or os.time()
    local today = os.date("%Y-%m-%d", now)
    local day = os.date("%Y-%m-%d", n)
    if day == today then
        return os.date("%H:%M", n)
    end
    if os.date("%Y", n) == os.date("%Y", now) then
        return os.date("%b %d", n)
    end
    return os.date("%Y-%m-%d", n)
end

---Right-column text: "Feed · 12:30" / "Feed · Jul 12" / feed-only / date-only.
-- Used as list row line 2 (and formerly Menu mandatory).
function ListFormat.rowMandatory(article, now)
    article = article or {}
    local date = ListFormat.formatArticleDate(
        article.updated or article.published or article.crawlTimeMsec,
        now
    )
    local feed = tostring(article.feed_title or "")
    if feed == "" or feed == "nil" then feed = "" end
    if feed ~= "" and date then
        return feed .. " · " .. date
    end
    if feed ~= "" then return feed end
    if date then return date end
    return nil
end

---Two-line list body: "● Title\\nFeed · 12:30".
function ListFormat.rowText(article, opts)
    opts = opts or {}
    article = article or {}
    local unread_mark = opts.unread_mark or "● "
    local read_mark = opts.read_mark or "○ "
    local marker = article.unread and unread_mark or read_mark
    local star = article.starred and (opts.star_mark or "★ ") or ""
    local title = tostring(opts.title or article.title or "Untitled")
    local line1 = marker .. star .. title
    local sub = ListFormat.rowMandatory(article, opts.now)
    if sub and sub ~= "" then
        return line1 .. "\n" .. sub
    end
    return line1
end

---Lookup unread count for a stream id from FreshRSS unread-count meta.
function ListFormat.unreadCountForStream(counts_meta, stream_id)
    if stream_id == nil or stream_id == "" then return nil end
    if type(counts_meta) ~= "table" then return nil end
    local list = counts_meta.unreadcounts
    if type(list) ~= "table" then
        -- Some callers may pass the array directly
        if counts_meta[1] and type(counts_meta[1]) == "table" then
            list = counts_meta
        else
            return nil
        end
    end
    local want = tostring(stream_id)
    for _, row in ipairs(list) do
        if type(row) == "table" and tostring(row.id) == want then
            return tonumber(row.count)
        end
    end
    return nil
end

return ListFormat
