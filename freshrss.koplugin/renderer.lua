local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local util = require("util")

local Renderer = {}

function Renderer:articleWidget(article, callbacks)
    local body = util.htmlToPlainTextIfHtml(tostring(article.html or ""))
    if body == "" then
        body = "No article content was provided by FreshRSS."
    end
    local published = tonumber(article.published) or os.time()
    local meta = (article.feed_title or "FreshRSS") .. "  ·  " .. os.date("%Y-%m-%d", published)
    local title = util.htmlEntitiesToUtf8(tostring(article.title or "Untitled"))
    local viewer
    viewer = TextViewer:new{
        title = title,
        title_multilines = true,
        text = meta .. "\n\n" .. body,
        text_type = "book_info",
        buttons_table = {
            {
                {
                    text = "Mark unread",
                    callback = function()
                        if callbacks.on_unread then callbacks.on_unread() end
                    end,
                },
                {
                    text = article.starred and "★ Unfavorite" or "☆ Favorite",
                    callback = function()
                        if callbacks.on_star then callbacks.on_star() end
                    end,
                },
                {
                    text = "Close",
                    callback = function()
                        UIManager:close(viewer)
                        if callbacks.on_back then callbacks.on_back() end
                    end,
                },
            },
        },
    }
    return viewer
end

return Renderer
