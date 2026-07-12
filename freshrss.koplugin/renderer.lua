local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local SpinWidget = require("ui/widget/spinwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local Input = Device.input
local Screen = Device.screen

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")
local Images = dofile(plugin_dir .. "/images.lua")

local Renderer = {}

local HTML_MAX_BYTES = 400 * 1024
local DEFAULT_FONT_SIZE = 20
local DEFAULT_TITLE_FONT_SIZE = 24
local FONT_SIZE_MIN = 12
local FONT_SIZE_MAX = 36
local DEFAULT_LINE_HEIGHT = 1.45
local LINE_HEIGHT_MIN = 1.0
local LINE_HEIGHT_MAX = 2.5
local LINE_HEIGHT_STEP = 0.05
-- Legacy discrete presets (still used by cycleLineHeight for quick tap).
local LINE_HEIGHTS = { 1.2, 1.45, 1.7 }
local DEFAULT_JUSTIFY = true
local DEFAULT_PAD_TOP = 0.2
local DEFAULT_PAD_SIDE = 0.5
local DEFAULT_PAD_BOTTOM = 0.2
local PAD_MIN = 0.0
local PAD_MAX = 3.0
local PAD_STEP = 0.1
-- Legacy discrete presets for cycle helpers / tests.
local PAD_TOP_VALUES = { 0.0, 0.2, 0.5, 1.0, 1.5 }
local PAD_SIDE_VALUES = { 0.2, 0.5, 0.8, 1.2, 1.6 }
local PAD_BOTTOM_VALUES = { 0.0, 0.2, 0.5, 1.0, 1.5 }

---Convert spacing setting (em-like units) to CSS px independent of article font size.
---MuPDF resolves `em` against the large body font, which made "1em" look huge.
local function padToPx(em)
    em = tonumber(em) or 0
    if em < 0 then em = 0 end
    local base = em * 10 -- 1.0 setting ≈ 10 CSS px before screen scale
    local ok, Device = pcall(require, "device")
    if ok and Device and Device.screen and Device.screen.scaleBySize then
        return math.floor(Device.screen:scaleBySize(base) + 0.5)
    end
    return math.floor(base + 0.5)
end

local function cssBase(line_height, show_images, justify, pad_top, pad_side, pad_bottom)
    local lh = tonumber(line_height) or DEFAULT_LINE_HEIGHT
    local align_css = justify and "text-align: justify; " or "text-align: left; "
    local img_css = show_images
        and "img { display: block; max-width: 100%; height: auto; margin: 0.5em 0; }"
        or "img { display: none; }"
    local top = padToPx(pad_top or DEFAULT_PAD_TOP)
    local side = padToPx(pad_side or DEFAULT_PAD_SIDE)
    local bottom = padToPx(pad_bottom or DEFAULT_PAD_BOTTOM)
    return string.format([[
html, body { margin: 0 !important; }
body { padding: %dpx %dpx %dpx %dpx; line-height: %s; %s}
body > *:first-child { margin-top: 0 !important; padding-top: 0 !important; }
p { margin: 0.35em 0; line-height: %s; %s}
p:first-child { margin-top: 0; }
h1, h2, h3, h4 { margin: 0.6em 0 0.3em; line-height: 1.25; }
h1:first-child, h2:first-child, h3:first-child, h4:first-child { margin-top: 0; }
a { text-decoration: underline; }
blockquote { margin: 0.5em 0; padding-left: 0.8em; border-left: 2px solid #888; }
pre, code { font-family: monospace; }
pre { white-space: pre-wrap; }
ul, ol { margin: 0.4em 0; padding-left: 1.4em; }
%s
]], top, side, bottom, side, tostring(lh), align_css, tostring(lh), align_css, img_css)
end

---Build MuPDF CSS including optional @font-face (FootnoteWidget-style).
function Renderer.buildCss(opts)
    opts = opts or {}
    local show_images = opts.show_images
    if show_images == nil then show_images = Renderer.readShowImages() end
    local line_height = opts.line_height or Renderer.readLineHeight()
    local justify = opts.justify
    if justify == nil then justify = Renderer.readJustifyText() end
    local font_face = opts.font_face
    if font_face == nil then font_face = Renderer.readFontFace() end
    local pad_top = opts.pad_top
    if pad_top == nil then pad_top = Renderer.readPadTop() end
    local pad_side = opts.pad_side
    if pad_side == nil then pad_side = Renderer.readPadSide() end
    local pad_bottom = opts.pad_bottom
    if pad_bottom == nil then pad_bottom = Renderer.readPadBottom() end

    local css = cssBase(line_height, show_images, justify, pad_top, pad_side, pad_bottom)
    if font_face and font_face ~= "" then
        css = css .. string.format(
            "\n@font-face { font-family: 'FreshRSSFont'; src: url('%s'); }\nbody { font-family: 'FreshRSSFont'; }\n",
            font_face:gsub("'", "")
        )
    end
    return css
end

function Renderer.sanitizeHtml(html)
    local body = tostring(html or "")
    if body == "" then return "" end

    body = body:gsub("<script[%s>].-</script>", "")
    body = body:gsub("<SCRIPT[%s>].-</SCRIPT>", "")
    body = body:gsub("<style[%s>].-</style>", "")
    body = body:gsub("<STYLE[%s>].-</STYLE>", "")
    body = body:gsub("<iframe[%s>].-</iframe>", "")
    body = body:gsub("<IFRAME[%s>].-</IFRAME>", "")
    body = body:gsub("<object[%s>].-</object>", "")
    body = body:gsub("<OBJECT[%s>].-</OBJECT>", "")
    body = body:gsub("<embed[^>]*>", "")
    body = body:gsub("<EMBED[^>]*>", "")
    body = body:gsub("<video[%s>].-</video>", "")
    body = body:gsub("<VIDEO[%s>].-</VIDEO>", "")
    body = body:gsub("<audio[%s>].-</audio>", "")
    body = body:gsub("<AUDIO[%s>].-</AUDIO>", "")
    -- Drop leading empty paragraphs / breaks that create a fake top margin.
    for _ = 1, 5 do
        local trimmed = body
            :gsub("^%s+", "")
            :gsub("^<%s*[pP][^>]*>%s*<%s*/%s*[pP]%s*>", "")
            :gsub("^<%s*[pP][^>]*>%s*&nbsp;%s*<%s*/%s*[pP]%s*>", "")
            :gsub("^<%s*[pP][^>]*>%s*<br%s*/?%s*>%s*<%s*/%s*[pP]%s*>", "")
            :gsub("^<%s*br%s*/?%s*>", "")
            :gsub("^&nbsp;", "")
        if trimmed == body then break end
        body = trimmed
    end
    -- Keep local <img src="file">; replace remote / missing with placeholder.
    body = body:gsub("<%s*[iI][mM][gG][^>]*>", function(tag)
        local src = tag:match("[sS][rR][cC]%s*=%s*\"([^\"]+)\"")
            or tag:match("[sS][rR][cC]%s*=%s*'([^']+)'")
            or tag:match("[sS][rR][cC]%s*=%s*([^%s>]+)")
        if src and src ~= "" and (
            src:match("^file:")
            or (not src:match("^https?://") and not src:match("^//") and src:sub(1, 5) ~= "data:")
        ) then
            return string.format('<img src="%s"/>', src:gsub('"', ""))
        end
        return " <span>[image]</span> "
    end)
    body = body:gsub("%s[oO][nN]%w+%s*=%s*\"[^\"]*\"", "")
    body = body:gsub("%s[oO][nN]%w+%s*=%s*'[^']*'", "")
    body = body:gsub("[hH][rR][eE][fF]%s*=%s*\"%s*[jJ][aA][vV][aA][sS][cC][rR][iI][pP][tT]:[^\"]*\"", "href=\"#\"")
    body = body:gsub("[hH][rR][eE][fF]%s*=%s*'%s*[jJ][aA][vV][aA][sS][cC][rR][iI][pP][tT]:[^']*'", "href=\"#\"")

    if #body > HTML_MAX_BYTES then
        body = body:sub(1, HTML_MAX_BYTES) .. "<p><em>[Article truncated for display]</em></p>"
    end
    return body
end

function Renderer.buildHtmlBody(article, opts)
    opts = opts or {}
    local raw = tostring(article and article.html or "")
    local prepared = raw
    local resource_dir = opts.html_resource_directory

    if opts.show_images then
        resource_dir = resource_dir
            or (opts.data_dir and Images.directory(opts.data_dir))
        if raw ~= "" then
            local map = opts.image_map
            if not map then
                local cached_dir
                map, cached_dir = Images.cachedMap(raw, opts.data_dir)
                resource_dir = resource_dir or cached_dir
            end
            -- Relative filenames only; ScrollHtmlWidget gets html_resource_directory.
            prepared = Images.rewriteHtml(raw, map or {})
        end
    elseif raw ~= "" then
        -- Placeholders for all images when disabled
        prepared = Images.rewriteHtml(raw, {})
    end

    local sanitized = Renderer.sanitizeHtml(prepared)
    if sanitized == "" then
        local plain = util.htmlToPlainTextIfHtml(raw)
        if plain == "" then
            plain = "No article content was provided by FreshRSS."
        end
        sanitized = "<p>" .. util.htmlEscape(plain):gsub("\n", "<br/>") .. "</p>"
    end
    return sanitized, resource_dir
end

function Renderer.readFontSize()
    local size = tonumber(G_reader_settings:readSetting("freshrss_viewer_font_size"))
    if not size then return DEFAULT_FONT_SIZE end
    if size < FONT_SIZE_MIN then size = FONT_SIZE_MIN end
    if size > FONT_SIZE_MAX then size = FONT_SIZE_MAX end
    return size
end

function Renderer.saveFontSize(size)
    size = tonumber(size) or DEFAULT_FONT_SIZE
    if size < FONT_SIZE_MIN then size = FONT_SIZE_MIN end
    if size > FONT_SIZE_MAX then size = FONT_SIZE_MAX end
    G_reader_settings:saveSetting("freshrss_viewer_font_size", size)
    G_reader_settings:flush()
end

function Renderer.readTitleFontSize()
    local size = tonumber(G_reader_settings:readSetting("freshrss_viewer_title_font_size"))
    if not size then return DEFAULT_TITLE_FONT_SIZE end
    if size < FONT_SIZE_MIN then size = FONT_SIZE_MIN end
    if size > FONT_SIZE_MAX then size = FONT_SIZE_MAX end
    return size
end

function Renderer.saveTitleFontSize(size)
    size = tonumber(size) or DEFAULT_TITLE_FONT_SIZE
    if size < FONT_SIZE_MIN then size = FONT_SIZE_MIN end
    if size > FONT_SIZE_MAX then size = FONT_SIZE_MAX end
    G_reader_settings:saveSetting("freshrss_viewer_title_font_size", size)
    G_reader_settings:flush()
end

function Renderer.readFontFace()
    local face = G_reader_settings:readSetting("freshrss_viewer_font_face")
    if type(face) == "string" and face ~= "" then return face end
    return nil
end

function Renderer.saveFontFace(face)
    if face and face ~= "" then
        G_reader_settings:saveSetting("freshrss_viewer_font_face", face)
    else
        G_reader_settings:delSetting("freshrss_viewer_font_face")
    end
    G_reader_settings:flush()
end

function Renderer.readLineHeight()
    local lh = tonumber(G_reader_settings:readSetting("freshrss_viewer_line_height"))
    if not lh then return DEFAULT_LINE_HEIGHT end
    return Renderer.clampLineHeight(lh)
end

function Renderer.clampLineHeight(lh)
    lh = tonumber(lh) or DEFAULT_LINE_HEIGHT
    if lh < LINE_HEIGHT_MIN then lh = LINE_HEIGHT_MIN end
    if lh > LINE_HEIGHT_MAX then lh = LINE_HEIGHT_MAX end
    return math.floor(lh * 100 + 0.5) / 100
end

function Renderer.saveLineHeight(lh)
    G_reader_settings:saveSetting("freshrss_viewer_line_height", Renderer.clampLineHeight(lh))
    G_reader_settings:flush()
end

function Renderer.cycleLineHeight(current)
    current = tonumber(current) or Renderer.readLineHeight()
    local idx = 1
    local best_dist = math.huge
    for i, v in ipairs(LINE_HEIGHTS) do
        local d = math.abs(v - current)
        if d < best_dist then
            best_dist = d
            idx = i
        end
    end
    local next_lh = LINE_HEIGHTS[(idx % #LINE_HEIGHTS) + 1]
    Renderer.saveLineHeight(next_lh)
    return next_lh
end

function Renderer.formatLineHeight(lh)
    return string.format("%.2f", Renderer.clampLineHeight(lh))
end

function Renderer.readShowImages()
    local value = G_reader_settings:readSetting("freshrss_viewer_show_images")
    if value == nil then return true end
    return value and true or false
end

function Renderer.saveShowImages(on)
    G_reader_settings:saveSetting("freshrss_viewer_show_images", on and true or false)
    G_reader_settings:flush()
end

function Renderer.readJustifyText()
    local value = G_reader_settings:readSetting("freshrss_viewer_justify_text")
    if value == nil then return DEFAULT_JUSTIFY end
    return value and true or false
end

function Renderer.saveJustifyText(on)
    G_reader_settings:saveSetting("freshrss_viewer_justify_text", on and true or false)
    G_reader_settings:flush()
end

local function clampEm(value, default)
    value = tonumber(value) or default
    if value < PAD_MIN then value = PAD_MIN end
    if value > PAD_MAX then value = PAD_MAX end
    return math.floor(value * 10 + 0.5) / 10
end

local function readEmSetting(key, default)
    local value = tonumber(G_reader_settings:readSetting(key))
    if not value then return default end
    return clampEm(value, default)
end

local function cycleEmSetting(key, current, allowed, default)
    current = tonumber(current) or default
    local idx = 1
    local best_dist = math.huge
    for i, v in ipairs(allowed) do
        local d = math.abs(v - current)
        if d < best_dist then
            best_dist = d
            idx = i
        end
    end
    local next_v = allowed[(idx % #allowed) + 1]
    G_reader_settings:saveSetting(key, next_v)
    G_reader_settings:flush()
    return next_v
end

function Renderer.readPadTop()
    return readEmSetting("freshrss_viewer_pad_top", DEFAULT_PAD_TOP)
end

function Renderer.savePadTop(v)
    G_reader_settings:saveSetting("freshrss_viewer_pad_top", clampEm(v, DEFAULT_PAD_TOP))
    G_reader_settings:flush()
end

function Renderer.cyclePadTop(current)
    return cycleEmSetting("freshrss_viewer_pad_top", current, PAD_TOP_VALUES, DEFAULT_PAD_TOP)
end

function Renderer.readPadSide()
    return readEmSetting("freshrss_viewer_pad_side", DEFAULT_PAD_SIDE)
end

function Renderer.savePadSide(v)
    G_reader_settings:saveSetting("freshrss_viewer_pad_side", clampEm(v, DEFAULT_PAD_SIDE))
    G_reader_settings:flush()
end

function Renderer.cyclePadSide(current)
    return cycleEmSetting("freshrss_viewer_pad_side", current, PAD_SIDE_VALUES, DEFAULT_PAD_SIDE)
end

function Renderer.readPadBottom()
    return readEmSetting("freshrss_viewer_pad_bottom", DEFAULT_PAD_BOTTOM)
end

function Renderer.savePadBottom(v)
    G_reader_settings:saveSetting("freshrss_viewer_pad_bottom", clampEm(v, DEFAULT_PAD_BOTTOM))
    G_reader_settings:flush()
end

function Renderer.cyclePadBottom(current)
    return cycleEmSetting("freshrss_viewer_pad_bottom", current, PAD_BOTTOM_VALUES, DEFAULT_PAD_BOTTOM)
end

function Renderer.formatPad(v)
    return string.format("%.1fem", clampEm(v, 0))
end

---Shared SpinWidget for continuous viewer spacing / line-height.
function Renderer.showSpacingSpin(opts)
    opts = opts or {}
    local UIManager = require("ui/uimanager")
    local SpinWidget = require("ui/widget/spinwidget")
    local widget = SpinWidget:new{
        title_text = opts.title or "Value",
        info_text = opts.info_text,
        value = opts.value,
        value_min = opts.value_min,
        value_max = opts.value_max,
        value_step = opts.value_step,
        value_hold_step = opts.value_hold_step or (opts.value_step * 5),
        precision = opts.precision or "%.1f",
        default_value = opts.default_value,
        ok_always_enabled = true,
        keep_shown_on_apply = opts.keep_shown_on_apply ~= false,
        callback = function(spin)
            if opts.callback then opts.callback(spin.value) end
        end,
    }
    UIManager:show(widget)
    return widget
end

local ArticleViewer = InputContainer:extend{
    name = "freshrss_article_viewer",
    article = nil,
    callbacks = nil,
    covers_fullscreen = true,
}

function ArticleViewer:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
    self.region = Geom:new{ w = screen_w, h = screen_h }
    self.align = "center"
    self.callbacks = self.callbacks or {}
    self.icons = self.icons or self.callbacks.icons
    self.font_size = Renderer.readFontSize()
    self.title_font_size = Renderer.readTitleFontSize()
    self.font_face = Renderer.readFontFace()
    self.line_height = Renderer.readLineHeight()
    self.show_images = Renderer.readShowImages()
    self.justify_text = Renderer.readJustifyText()
    self.pad_top = Renderer.readPadTop()
    self.pad_side = Renderer.readPadSide()
    self.pad_bottom = Renderer.readPadBottom()
    self.image_map = self.callbacks.image_map
    self.html_resource_directory = self.callbacks.html_resource_directory
    self.data_dir = self.callbacks.data_dir
    self:build()

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            ScrollDown = { { Input.group.PgFwd } },
            ScrollUp = { { Input.group.PgBack } },
            ShowMenu = { { "Menu" } },
        }
    end

    if Device:isTouchDevice() then
        local range = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
        self.ges_events = {
            SwipeNav = {
                GestureRange:new{ ges = "swipe", range = range },
            },
            PanScroll = {
                GestureRange:new{ ges = "pan", range = range },
            },
            PanReleaseScroll = {
                GestureRange:new{ ges = "pan_release", range = range },
            },
        }
    end
end

function ArticleViewer:_actionButtons()
    local article = self.article or {}
    local icons = self.icons
    -- Single compact icon row (KOReader Button is icon XOR text). Disabled
    -- prev/next dim via IconWidget; nav still uses stable callbacks.prev/next_id.
    if icons then
        local star_key = article.starred and "star_filled" or "star"
        return {
            {
                icons:button("chevron_left", {
                    enabled = self.callbacks.prev_id ~= nil,
                    callback = function()
                        if self.callbacks.on_prev then self.callbacks.on_prev() end
                    end,
                }),
                icons:button("circle", {
                    callback = function()
                        if self.callbacks.on_unread then self.callbacks.on_unread() end
                    end,
                }),
                icons:button(star_key, {
                    callback = function()
                        if self.callbacks.on_star then self.callbacks.on_star() end
                    end,
                }),
                icons:button("book_open", {
                    enabled = article.url ~= nil and article.url ~= "",
                    callback = function()
                        if self.callbacks.on_open_original then self.callbacks.on_open_original() end
                    end,
                }),
                icons:button("chevron_right", {
                    enabled = self.callbacks.next_id ~= nil,
                    callback = function()
                        if self.callbacks.on_next then self.callbacks.on_next() end
                    end,
                }),
            },
        }
    end
    return {
        {
            {
                text = "◀ Prev",
                enabled = self.callbacks.prev_id ~= nil,
                callback = function()
                    if self.callbacks.on_prev then self.callbacks.on_prev() end
                end,
            },
            {
                text = "Next ▶",
                enabled = self.callbacks.next_id ~= nil,
                callback = function()
                    if self.callbacks.on_next then self.callbacks.on_next() end
                end,
            },
        },
        {
            {
                text = "Unread",
                callback = function()
                    if self.callbacks.on_unread then self.callbacks.on_unread() end
                end,
            },
            {
                text = article.starred and "★ Fav" or "☆ Fav",
                callback = function()
                    if self.callbacks.on_star then self.callbacks.on_star() end
                end,
            },
            {
                text = "Original",
                enabled = article.url ~= nil and article.url ~= "",
                callback = function()
                    if self.callbacks.on_open_original then self.callbacks.on_open_original() end
                end,
            },
        },
    }
end

function ArticleViewer:refreshActionButtons()
    local width = self.dimen.w
    self.button_table = ButtonTable:new{
        width = width,
        buttons = self:_actionButtons(),
        zero_sep = true,
        show_parent = self,
    }
    if self.frame then
        self.frame[1] = VerticalGroup:new{
            align = "left",
            self.title_bar,
            self.html_widget,
            self.button_table,
        }
        UIManager:setDirty(self, "ui")
    end
end

function ArticleViewer:_buildTitleBar()
    local article = self.article or {}
    local title = util.htmlEntitiesToUtf8(tostring(article.title or "Untitled"))
    local published = tonumber(article.published) or os.time()
    local index = self.callbacks.index or 0
    local total = self.callbacks.total or 0
    local subtitle = string.format("%s  ·  %s",
        article.feed_title or "FreshRSS",
        os.date("%Y-%m-%d", published))
    if total > 0 and index > 0 then
        subtitle = subtitle .. string.format("  ·  %d/%d", index, total)
    end

    local width = self.dimen.w
    self.title_bar = TitleBar:new{
        width = width,
        fullscreen = true,
        title = title,
        subtitle = subtitle,
        title_face = Font:getFace("smalltfont", self.title_font_size),
        title_multilines = true,
        with_bottom_line = true,
        title_top_padding = Size.padding.small,
        title_subtitle_v_padding = Screen:scaleBySize(1),
        bottom_v_padding = Size.padding.small,
        left_icon = "appbar.menu",
        left_icon_size_ratio = 0.7,
        left_icon_tap_callback = function()
            self:onShowViewSettings()
        end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
end

function ArticleViewer:build()
    local width = self.dimen.w
    self:_buildTitleBar()

    self.button_table = ButtonTable:new{
        width = width,
        buttons = self:_actionButtons(),
        zero_sep = true,
        show_parent = self,
    }

    self:_buildHtmlWidget()

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        width = width,
        height = self.dimen.h,
        VerticalGroup:new{
            align = "left",
            self.title_bar,
            self.html_widget,
            self.button_table,
        },
    }
    self[1] = WidgetContainer:new{
        align = "center",
        dimen = self.region,
        self.frame,
    }
end

function ArticleViewer:reinitTitle()
    self:_buildTitleBar()
    self:reinit()
end

function ArticleViewer:_availableHeight()
    local h = self.dimen.h
        - self.title_bar:getHeight()
        - self.button_table:getSize().h
    if h < Screen:scaleBySize(120) then
        h = Screen:scaleBySize(120)
    end
    return h
end

function ArticleViewer:_buildHtmlWidget()
    if self.html_widget and self.html_widget.free then
        self.html_widget:free()
    end
    local article = self.article or {}
    local width = self.dimen.w
    local height = self:_availableHeight()
    local html_body, resource_dir = Renderer.buildHtmlBody(article, {
        show_images = self.show_images,
        image_map = self.image_map,
        html_resource_directory = self.html_resource_directory,
        data_dir = self.data_dir,
    })
    if resource_dir then
        self.html_resource_directory = resource_dir
    end
    local font_px = Screen:scaleBySize(self.font_size)
    local css = Renderer.buildCss({
        show_images = self.show_images,
        line_height = self.line_height,
        justify = self.justify_text,
        font_face = self.font_face,
        pad_top = self.pad_top,
        pad_side = self.pad_side,
        pad_bottom = self.pad_bottom,
    })
    local widget_opts = {
        html_body = html_body,
        css = css,
        default_font_size = font_px,
        is_xhtml = false,
        width = width,
        height = height,
        dialog = self,
        html_link_tapped_callback = function(link)
            local href = link and (link.uri or link.externalurl or link.url or link.href)
            if href and self.callbacks.on_link then
                self.callbacks.on_link(href)
            end
        end,
    }
    if self.show_images and self.html_resource_directory then
        widget_opts.html_resource_directory = self.html_resource_directory
    end
    local ok, html_widget_or_err = pcall(function()
        return ScrollHtmlWidget:new(widget_opts)
    end)
    if ok and html_widget_or_err then
        self.html_widget = html_widget_or_err
    else
        local plain = util.htmlToPlainTextIfHtml(tostring(article.html or ""))
        if plain == "" then plain = "Unable to render article HTML." end
        self.html_widget = ScrollHtmlWidget:new{
            html_body = "<p>" .. util.htmlEscape(plain):gsub("\n", "<br/>") .. "</p>",
            css = css,
            default_font_size = font_px,
            is_xhtml = false,
            width = width,
            height = height,
            dialog = self,
        }
    end
end

function ArticleViewer:reinit()
    self:_buildHtmlWidget()
    self.frame[1] = VerticalGroup:new{
        align = "left",
        self.title_bar,
        self.html_widget,
        self.button_table,
    }
    UIManager:setDirty(self, "ui")
end

function ArticleViewer:applyImageMap(image_map, resource_dir)
    self.image_map = image_map
    self.html_resource_directory = resource_dir
    self:reinit()
end

function ArticleViewer:onShowMenu()
    self:onShowViewSettings()
    return true
end

function ArticleViewer:onShowFontPicker()
    local FontList = require("fontlist")
    local fonts = FontList:getFontList() or {}
    local entries = {
        {
            text = "Default (system)",
            callback = function()
                UIManager:close(self.font_menu)
                self.font_menu = nil
                self.font_face = nil
                Renderer.saveFontFace(nil)
                self:reinit()
            end,
        },
    }
    for _, path in ipairs(fonts) do
        local name = path:match("([^/]+)$") or path
        local selected = self.font_face == path and " ✓" or ""
        table.insert(entries, {
            text = name .. selected,
            callback = function()
                UIManager:close(self.font_menu)
                self.font_menu = nil
                self.font_face = path
                Renderer.saveFontFace(path)
                self:reinit()
            end,
        })
    end
    if self.font_menu then
        UIManager:close(self.font_menu)
    end
    self.font_menu = Menu:new{
        title = "Font",
        item_table = entries,
        is_popout = false,
        is_borderless = true,
        covers_fullscreen = true,
        close_callback = function()
            self.font_menu = nil
        end,
    }
    UIManager:show(self.font_menu, "ui")
end

function ArticleViewer:onShowViewSettings()
    local dialog
    local font_label = "Default"
    if self.font_face then
        font_label = self.font_face:match("([^/]+)$") or self.font_face
    end
    local buttons = {
        {
            {
                text_func = function()
                    return string.format("Font size: %d", self.font_size)
                end,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    local widget = SpinWidget:new{
                        title_text = "Font size",
                        value = self.font_size,
                        value_min = FONT_SIZE_MIN,
                        value_max = FONT_SIZE_MAX,
                        default_value = DEFAULT_FONT_SIZE,
                        keep_shown_on_apply = true,
                        callback = function(spin)
                            self.font_size = spin.value
                            Renderer.saveFontSize(self.font_size)
                            self:reinit()
                        end,
                    }
                    UIManager:show(widget)
                end,
            },
        },
        {
            {
                text_func = function()
                    return string.format("Title font size: %d", self.title_font_size)
                end,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    local widget = SpinWidget:new{
                        title_text = "Title font size",
                        value = self.title_font_size,
                        value_min = FONT_SIZE_MIN,
                        value_max = FONT_SIZE_MAX,
                        default_value = DEFAULT_TITLE_FONT_SIZE,
                        keep_shown_on_apply = true,
                        callback = function(spin)
                            self.title_font_size = spin.value
                            Renderer.saveTitleFontSize(self.title_font_size)
                            self:reinitTitle()
                        end,
                    }
                    UIManager:show(widget)
                end,
            },
        },
        {
            {
                text_func = function()
                    return "Font: " .. font_label
                end,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:onShowFontPicker()
                end,
            },
        },
        {
            {
                text_func = function()
                    return string.format("Line height: %s", Renderer.formatLineHeight(self.line_height))
                end,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    Renderer.showSpacingSpin({
                        title = "Line height",
                        info_text = "Article body line spacing",
                        value = self.line_height,
                        value_min = LINE_HEIGHT_MIN,
                        value_max = LINE_HEIGHT_MAX,
                        value_step = LINE_HEIGHT_STEP,
                        precision = "%.2f",
                        default_value = DEFAULT_LINE_HEIGHT,
                        callback = function(value)
                            self.line_height = Renderer.clampLineHeight(value)
                            Renderer.saveLineHeight(self.line_height)
                            self:reinit()
                        end,
                    })
                end,
            },
        },
        {
            {
                text_func = function()
                    return self.show_images and "Show images: on" or "Show images: off"
                end,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self.show_images = not self.show_images
                    Renderer.saveShowImages(self.show_images)
                    self:reinit()
                    if self.show_images and self.callbacks.on_images_enabled then
                        self.callbacks.on_images_enabled()
                    end
                end,
            },
        },
        {
            {
                text_func = function()
                    return self.justify_text and "Justify text: on" or "Justify text: off"
                end,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self.justify_text = not self.justify_text
                    Renderer.saveJustifyText(self.justify_text)
                    self:reinit()
                end,
            },
        },
        {
            {
                text_func = function()
                    return "Side padding: " .. Renderer.formatPad(self.pad_side)
                end,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    Renderer.showSpacingSpin({
                        title = "Side padding",
                        info_text = "Left and right body padding (em)",
                        value = self.pad_side,
                        value_min = PAD_MIN,
                        value_max = PAD_MAX,
                        value_step = PAD_STEP,
                        precision = "%.1f",
                        default_value = DEFAULT_PAD_SIDE,
                        callback = function(value)
                            self.pad_side = value
                            Renderer.savePadSide(value)
                            self.pad_side = Renderer.readPadSide()
                            self:reinit()
                        end,
                    })
                end,
            },
        },
        {
            {
                text_func = function()
                    return "Top margin: " .. Renderer.formatPad(self.pad_top)
                end,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    Renderer.showSpacingSpin({
                        title = "Top margin",
                        info_text = "Top body padding (em)",
                        value = self.pad_top,
                        value_min = PAD_MIN,
                        value_max = PAD_MAX,
                        value_step = PAD_STEP,
                        precision = "%.1f",
                        default_value = DEFAULT_PAD_TOP,
                        callback = function(value)
                            Renderer.savePadTop(value)
                            self.pad_top = Renderer.readPadTop()
                            self:reinit()
                        end,
                    })
                end,
            },
        },
        {
            {
                text_func = function()
                    return "Bottom margin: " .. Renderer.formatPad(self.pad_bottom)
                end,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    Renderer.showSpacingSpin({
                        title = "Bottom margin",
                        info_text = "Bottom body padding (em)",
                        value = self.pad_bottom,
                        value_min = PAD_MIN,
                        value_max = PAD_MAX,
                        value_step = PAD_STEP,
                        precision = "%.1f",
                        default_value = DEFAULT_PAD_BOTTOM,
                        callback = function(value)
                            Renderer.savePadBottom(value)
                            self.pad_bottom = Renderer.readPadBottom()
                            self:reinit()
                        end,
                    })
                end,
            },
        },
    }
    dialog = ButtonDialog:new{
        title = "View settings",
        shrink_unneeded_width = true,
        buttons = buttons,
        anchor = function()
            if self.title_bar.left_button and self.title_bar.left_button.image then
                return self.title_bar.left_button.image.dimen
            end
        end,
    }
    UIManager:show(dialog)
    return true
end

function ArticleViewer:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
    return true
end

function ArticleViewer:scroll(direction)
    if self.html_widget then
        self.html_widget:scrollText(direction)
    end
    return true
end

function ArticleViewer:onScrollDown()
    return self:scroll(1)
end

function ArticleViewer:onScrollUp()
    return self:scroll(-1)
end

function ArticleViewer:onSwipeNav(_, ges)
    if ges.direction == "north" then
        return self:scroll(1)
    elseif ges.direction == "south" then
        return self:scroll(-1)
    elseif ges.direction == "west" then
        if self.callbacks.on_next and self.callbacks.next_id then
            self.callbacks.on_next()
            return true
        end
    elseif ges.direction == "east" then
        if self.callbacks.on_prev and self.callbacks.prev_id then
            self.callbacks.on_prev()
            return true
        end
    end
end

function ArticleViewer:onPanScroll()
    return true
end

function ArticleViewer:onPanReleaseScroll(_, ges)
    if ges.from_mousewheel and ges.relative and ges.relative.y then
        if ges.relative.y < 0 then
            return self:scroll(1)
        elseif ges.relative.y > 0 then
            return self:scroll(-1)
        end
        return true
    end
end

function ArticleViewer:onClose()
    -- Close only the viewer — never tear down Home / the article list.
    UIManager:close(self)
    if self.font_menu then
        UIManager:close(self.font_menu)
        self.font_menu = nil
    end
    if self.html_widget and self.html_widget.free then
        self.html_widget:free()
        self.html_widget = nil
    end
    if self.callbacks.on_back then self.callbacks.on_back() end
    return true
end

function ArticleViewer:onCloseWidget()
    if self.html_widget and self.html_widget.free then
        self.html_widget:free()
        self.html_widget = nil
    end
    UIManager:setDirty(nil, function()
        return "ui", self.dimen
    end)
end

function Renderer:articleWidget(article, callbacks)
    callbacks = callbacks or {}
    return ArticleViewer:new{
        article = article,
        callbacks = callbacks,
        icons = callbacks.icons,
    }
end

Renderer.ArticleViewer = ArticleViewer
Renderer.HTML_MAX_BYTES = HTML_MAX_BYTES
Renderer.DEFAULT_FONT_SIZE = DEFAULT_FONT_SIZE
Renderer.DEFAULT_TITLE_FONT_SIZE = DEFAULT_TITLE_FONT_SIZE
Renderer.FONT_SIZE_MIN = FONT_SIZE_MIN
Renderer.FONT_SIZE_MAX = FONT_SIZE_MAX
Renderer.DEFAULT_LINE_HEIGHT = DEFAULT_LINE_HEIGHT
Renderer.LINE_HEIGHT_MIN = LINE_HEIGHT_MIN
Renderer.LINE_HEIGHT_MAX = LINE_HEIGHT_MAX
Renderer.LINE_HEIGHT_STEP = LINE_HEIGHT_STEP
Renderer.DEFAULT_JUSTIFY = DEFAULT_JUSTIFY
Renderer.LINE_HEIGHTS = LINE_HEIGHTS
Renderer.DEFAULT_PAD_TOP = DEFAULT_PAD_TOP
Renderer.DEFAULT_PAD_SIDE = DEFAULT_PAD_SIDE
Renderer.DEFAULT_PAD_BOTTOM = DEFAULT_PAD_BOTTOM
Renderer.PAD_MIN = PAD_MIN
Renderer.PAD_MAX = PAD_MAX
Renderer.PAD_STEP = PAD_STEP
Renderer.Images = Images

return Renderer
