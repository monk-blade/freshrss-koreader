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
local time = require("ui/time")
local Input = Device.input
local Screen = Device.screen

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")
local Images = dofile(plugin_dir .. "/images.lua")
local ListFonts = dofile(plugin_dir .. "/list_fonts.lua")

local SettingsUI
local function getSettingsUI()
    if not SettingsUI then
        SettingsUI = dofile(plugin_dir .. "/settings_ui.lua")
    end
    return SettingsUI
end

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
local DEFAULT_PAD_TOP = 0.0
local DEFAULT_PAD_SIDE = 0.15
local DEFAULT_PAD_BOTTOM = 0.0
local PAD_MIN = 0.0
local PAD_MAX = 3.0
local PAD_STEP = 0.1
-- Legacy discrete presets for cycle helpers / tests.
local PAD_TOP_VALUES = { 0.0, 0.2, 0.5, 1.0, 1.5 }
local PAD_SIDE_VALUES = { 0.0, 0.15, 0.3, 0.5, 0.8 }
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
        and "img { display: block; max-width: 100%; height: auto; margin: 0.35em 0; }"
        or "img { display: none; }"
    local top = padToPx(pad_top or DEFAULT_PAD_TOP)
    local side = padToPx(pad_side or DEFAULT_PAD_SIDE)
    local bottom = padToPx(pad_bottom or DEFAULT_PAD_BOTTOM)
    return string.format([[
html, body { margin: 0 !important; padding: 0 !important; }
body { padding: %dpx %dpx %dpx %dpx !important; margin: 0 !important; line-height: %s; %s}
body > *:first-child,
body > *:first-child > *:first-child,
body > *:first-child > *:first-child > *:first-child,
body > *:first-child > *:first-child > *:first-child > *:first-child {
  margin-top: 0 !important; padding-top: 0 !important;
}
body > div:first-child, body > section:first-child, body > article:first-child,
body > header:first-child, body > main:first-child, body > figure:first-child,
body > p:first-child, body > h1:first-child, body > h2:first-child,
body > ul:first-child, body > ol:first-child, body > table:first-child,
body > blockquote:first-child {
  margin-top: 0 !important; padding-top: 0 !important;
}
p { margin: 0.25em 0; line-height: %s; %s}
p:first-child { margin-top: 0 !important; }
h1, h2, h3, h4 { margin: 0.4em 0 0.2em; line-height: 1.2; }
h1:first-child, h2:first-child, h3:first-child, h4:first-child { margin-top: 0 !important; }
img:first-child, body > img:first-child { margin-top: 0 !important; }
a { text-decoration: underline; }
blockquote { margin: 0.35em 0; padding-left: 0.7em; border-left: 2px solid #888; }
blockquote:first-child { margin-top: 0 !important; }
pre, code { font-family: monospace; white-space: pre-wrap; overflow-wrap: break-word; word-break: break-word; max-width: 100%%; }
table { width: 100%%; max-width: 100%%; table-layout: fixed; border-collapse: collapse; word-break: break-word; overflow-wrap: break-word; margin: 0.25em 0; }
td, th { word-break: break-word; overflow-wrap: break-word; padding: 0.15em 0.25em; vertical-align: top; }
figure, svg, canvas, video { max-width: 100%%; height: auto; margin: 0.25em 0; }
figure:first-child { margin-top: 0 !important; }
div, section, article, aside { max-width: 100%%; overflow-wrap: break-word; word-break: break-word; margin-top: 0; }
ul, ol { margin: 0.3em 0; padding-left: 1.2em; }
ul:first-child, ol:first-child { margin-top: 0 !important; }
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
    local viewer_fonts = opts.viewer_fonts
    if viewer_fonts == nil then viewer_fonts = Renderer.readViewerFonts() end
    local pad_top = opts.pad_top
    if pad_top == nil then pad_top = Renderer.readPadTop() end
    local pad_side = opts.pad_side
    if pad_side == nil then pad_side = Renderer.readPadSide() end
    local pad_bottom = opts.pad_bottom
    if pad_bottom == nil then pad_bottom = Renderer.readPadBottom() end

    local css = cssBase(line_height, show_images, justify, pad_top, pad_side, pad_bottom)
    if viewer_fonts and (viewer_fonts.latin or viewer_fonts.devanagari or viewer_fonts.gujarati) then
        css = css .. "\n" .. ListFonts.buildViewerFontCss(viewer_fonts)
    elseif font_face and font_face ~= "" then
        local resolved = ListFonts.resolveFontPath(font_face)
            or ListFonts.absoluteFontPath(font_face)
        if resolved then
            css = css .. string.format(
                "\n@font-face { font-family: 'FreshRSSFont'; src: url('%s'); }\nbody { font-family: 'FreshRSSFont'; }\n",
                resolved:gsub("\\", "/"):gsub("'", "\\'")
            )
        end
    end
    return css
end

---Resolved viewer font paths for MuPDF CSS (Latin / Devanagari / Gujarati).
function Renderer.readViewerFonts()
    return ListFonts.resolveViewerFonts()
end

---Human-readable image toggle label for View settings.
function Renderer.formatShowImagesLabel(show_images, stats)
    stats = stats or {}
    local total = tonumber(stats.total) or 0
    local cached = tonumber(stats.cached) or 0
    if not show_images then
        if total > 0 then
            return string.format("Show images: off (%d hidden)", total)
        end
        return "Show images: off"
    end
    if total > 0 then
        if cached >= total then
            return string.format("Show images: on (%d cached)", cached)
        end
        if cached > 0 then
            return string.format("Show images: on (%d/%d cached · tap to fetch)", cached, total)
        end
        return string.format("Show images: on (%d · tap to fetch)", total)
    end
    return "Show images: on"
end

---Placeholder text for remote/missing images in sanitized HTML.
function Renderer.imagePlaceholderText(opts)
    opts = opts or {}
    if opts.show_images == false then
        return "[image hidden]"
    end
    return "[image · tap to fetch]"
end

function Renderer.sanitizeHtml(html, opts)
    opts = opts or {}
    local placeholder = Renderer.imagePlaceholderText(opts)
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
    -- Drop leading empty wrappers / breaks that create a fake top margin.
    for _ = 1, 12 do
        local trimmed = body
            :gsub("^%s+", "")
            :gsub("^<%s*[pP][^>]*>%s*<%s*/%s*[pP]%s*>", "")
            :gsub("^<%s*[pP][^>]*>%s*&nbsp;%s*<%s*/%s*[pP]%s*>", "")
            :gsub("^<%s*[pP][^>]*>%s*<br%s*/?%s*>%s*<%s*/%s*[pP]%s*>", "")
            :gsub("^<%s*[pP][^>]*>%s+<%s*/%s*[pP]%s*>", "")
            :gsub("^<%s*[dD][iI][vV][^>]*>%s*<%s*/%s*[dD][iI][vV]%s*>", "")
            :gsub("^<%s*[sS][pP][aA][nN][^>]*>%s*<%s*/%s*[sS][pP][aA][nN]%s*>", "")
            :gsub("^<%s*[dD][iI][vV][^>]*>%s*&nbsp;%s*<%s*/%s*[dD][iI][vV]%s*>", "")
            :gsub("^<%s*[sS][eE][cC][tT][iI][oO][nN][^>]*>%s*<%s*/%s*[sS][eE][cC][tT][iI][oO][nN]%s*>", "")
            :gsub("^<%s*[aA][rR][tT][iI][cC][lL][eE][^>]*>%s*<%s*/%s*[aA][rR][tT][iI][cC][lL][eE]%s*>", "")
            :gsub("^<%s*[hH][eE][aA][dD][eE][rR][^>]*>%s*<%s*/%s*[hH][eE][aA][dD][eE][rR]%s*>", "")
            :gsub("^<%s*[hH][rR][^>]*/?%s*>", "")
            :gsub("^<%s*[fF][iI][gG][uU][rR][eE][^>]*>%s*<%s*/%s*[fF][iI][gG][uU][rR][eE]%s*>", "")
            :gsub("^<%s*br%s*/?%s*>", "")
            :gsub("^&nbsp;", "")
            :gsub("^&#160;", "")
            :gsub("^&#xA0;", "")
            -- Strip leading inline top margin/padding on the first open tag.
            :gsub("^(<%s*%w+[^>]-)%s[sS][tT][yY][lL][eE]%s*=%s*\"([^\"]*)\"", function(open, style)
                local cleaned = style
                    :gsub("[Mm][Aa][Rr][Gg][Ii][Nn]%-[Tt][Oo][Pp]%s*:[^;]*;?", "")
                    :gsub("[Pp][Aa][Dd][Dd][Ii][Nn][Gg]%-[Tt][Oo][Pp]%s*:[^;]*;?", "")
                    :gsub("[Mm][Aa][Rr][Gg][Ii][Nn]%s*:[^;]*;?", "")
                    :gsub("^%s*;%s*", "")
                    :gsub("%s*;%s*$", "")
                    :gsub("^%s+", "")
                    :gsub("%s+$", "")
                if cleaned == "" then
                    return open
                end
                return open .. ' style="' .. cleaned .. '"'
            end)
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
        return string.format(' <span>%s</span> ', placeholder)
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

local function normalizeTitleText(s)
    s = util.htmlEntitiesToUtf8(tostring(s or ""))
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s:lower()
end

---Drop a leading h1/h2 that repeats the article title (common in feed HTML).
function Renderer.stripDuplicateLeadingTitle(html, title)
    html = tostring(html or "")
    local want = normalizeTitleText(title)
    if want == "" then return html end
    local leading = html:match("^%s*<h[12][^>]*>(.-)</h[12]>")
    if leading and normalizeTitleText(leading) == want then
        html = html:gsub("^%s*<h[12][^>]*>.-</h[12]>", "", 1)
    end
    return html
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
            prepared = Images.rewriteHtml(raw, map or {}, { show_images = true })
        end
    elseif raw ~= "" then
        -- Placeholders for all images when disabled
        prepared = Images.rewriteHtml(raw, {}, { show_images = false })
    end

    local sanitized = Renderer.sanitizeHtml(prepared, { show_images = opts.show_images })
    sanitized = Renderer.stripDuplicateLeadingTitle(sanitized, article and article.title)
    if sanitized ~= prepared then
        sanitized = Renderer.sanitizeHtml(sanitized, { show_images = opts.show_images })
    end
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
    return ListFonts.readViewerLatinFont()
end

function Renderer.saveFontFace(face)
    ListFonts.saveViewerLatinFont(face)
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

    -- Stub enough of ReaderUI for ReaderDictionary (FileManager pattern).
    -- Dictionary is created lazily — a failed require/init must not kill openArticle.
    self.menu = { registerToMainMenu = function() end }
    self.doc_props = {
        display_title = util.htmlEntitiesToUtf8(tostring((self.article or {}).title or "FreshRSS")),
    }
    self.dictionary = nil
    self._dictionary_failed = false

    self:build()

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            ScrollDown = { { Input.group.PgFwd } },
            ScrollUp = { { Input.group.PgBack } },
            ShowMenu = { { "Menu" } },
        }
        if Device.hasKeyboard and Device:hasKeyboard() then
            self.key_events.ShowDictionaryLookup = { { "Alt", "D" }, { "Ctrl", "D" } }
        end
    end

    if Device:isTouchDevice() then
        local range = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
        local hold_pan_rate = G_reader_settings:readSetting("hold_pan_rate")
        if not hold_pan_rate then
            hold_pan_rate = Screen.low_pan_rate and 5.0 or 30.0
        end
        self.ges_events = {
            TapNav = {
                GestureRange:new{ ges = "tap", range = range },
            },
            SwipeNav = {
                GestureRange:new{ ges = "swipe", range = range },
            },
            PanScroll = {
                GestureRange:new{ ges = "pan", range = range },
            },
            PanReleaseScroll = {
                GestureRange:new{ ges = "pan_release", range = range },
            },
            -- Hold-to-select → KOReader dictionary (same pattern as FootnoteWidget).
            HoldStartText = {
                GestureRange:new{ ges = "hold", range = range },
            },
            HoldPanText = {
                GestureRange:new{
                    ges = "hold_pan",
                    range = range,
                    rate = hold_pan_rate,
                },
            },
            HoldReleaseText = {
                GestureRange:new{ ges = "hold_release", range = range },
                args = function(text, hold_duration)
                    self:onDictionarySelection(text, hold_duration)
                end,
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
    local published = tonumber(article.published) or tonumber(article.updated) or os.time()
    local index = self.callbacks.index or 0
    local total = self.callbacks.total or 0
    -- Title stays readable (no shrink-to-fit); feed · date · index on subtitle.
    local subtitle = string.format("%s  ·  %s",
        article.feed_title or "FreshRSS",
        os.date("%Y-%m-%d", published))
    if total > 0 and index > 0 then
        subtitle = subtitle .. string.format("  ·  %d/%d", index, total)
    end

    self.doc_props = { display_title = title }

    local width = self.dimen.w
    self.title_bar = TitleBar:new{
        width = width,
        fullscreen = true,
        title = title,
        subtitle = subtitle,
        title_face = Font:getFace("smalltfont", self.title_font_size)
            or Font:getFace("x_smalltfont")
            or Font:getFace("cfont"),
        title_multilines = true,
        title_shrink_font_to_fit = false,
        with_bottom_line = true,
        title_top_padding = 0,
        title_subtitle_v_padding = 0,
        bottom_v_padding = 0,
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

function ArticleViewer:_hardenScrollHtml(widget)
    -- KOReader VerticalScrollBar only sets touch_dimen in paintTo when enable=true.
    -- Disabled bars (single-page articles) still receive gestures → nil touch_dimen crash
    -- on Kindle Paperwhite. See crash.log: verticalscrollbar.lua:77.
    if not widget or not widget.v_scroll_bar then return widget end
    local bar = widget.v_scroll_bar
    if not bar.touch_dimen then
        bar.touch_dimen = Geom:new{ x = 0, y = 0, w = 0, h = 0 }
    end
    if not bar.enable then
        bar.ges_events = nil
        bar.scroll_callback = nil
    else
        -- Wrap scroll handler so a race before first paint cannot nil-index.
        local orig = bar.onTapScroll
        if type(orig) == "function" and not bar._freshrss_hardened then
            bar.onTapScroll = function(self, arg, ges)
                if not self.touch_dimen then return true end
                return orig(self, arg, ges)
            end
            bar.onHoldScroll = bar.onTapScroll
            bar.onHoldPanScroll = bar.onTapScroll
            bar.onHoldReleaseScroll = bar.onTapScroll
            bar.onPanScroll = bar.onTapScroll
            bar.onPanScrollRelease = bar.onTapScroll
            bar._freshrss_hardened = true
        end
    end
    return widget
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
        viewer_fonts = Renderer.readViewerFonts(),
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
        highlight_text_selection = true,
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
        self.html_widget = self:_hardenScrollHtml(html_widget_or_err)
        return
    end
    local plain = util.htmlToPlainTextIfHtml(tostring(article.html or ""))
    if plain == "" then plain = "Unable to render article HTML." end
    local fallback_opts = {
        html_body = "<p>" .. util.htmlEscape(plain):gsub("\n", "<br/>") .. "</p>",
        css = css,
        default_font_size = font_px,
        is_xhtml = false,
        width = width,
        height = height,
        dialog = self,
        highlight_text_selection = true,
    }
    local ok2, fallback = pcall(function()
        return ScrollHtmlWidget:new(fallback_opts)
    end)
    if ok2 and fallback then
        self.html_widget = self:_hardenScrollHtml(fallback)
        return
    end
    local ok3, last = pcall(function()
        return ScrollHtmlWidget:new{
            html_body = "<p>Unable to render this article on this device.</p>",
            css = "body { margin: 0; padding: 8px; }",
            default_font_size = font_px,
            is_xhtml = false,
            width = width,
            height = height,
            dialog = self,
        }
    end)
    if ok3 and last then
        self.html_widget = self:_hardenScrollHtml(last)
    else
        self.html_widget = {
            scrollText = function() end,
            free = function() end,
            htmlbox_widget = { page_number = 1, page_count = 1 },
        }
    end
end

function ArticleViewer:reinit()
    if self._closing or self._html_released then return end
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
    if self._closing or self._html_released then return end
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
        is_enable_shortcut = false,
        close_callback = function()
            self.font_menu = nil
        end,
    }
    UIManager:show(self.font_menu, "ui")
end

function ArticleViewer:_imageStats()
    local article = self.article or {}
    local html = tostring(article.html or "")
    if html == "" then return { total = 0, cached = 0 } end
    if Images.countImageStats then
        return Images.countImageStats(html, self.data_dir)
    end
    local total = #(Images.extractImageUrls(html) or {})
    return { total = total, cached = 0 }
end

function ArticleViewer:onShowViewSettings()
    local icons = self.icons
    local function iname(key)
        if icons and icons.name then return icons:name(key) end
        return "freshrss." .. key:gsub("_", "-")
    end
    local font_label = "Default"
    if self.font_face then
        font_label = ListFonts.displayName(self.font_face)
    end
    local function reopen()
        if self.view_settings_panel then
            UIManager:close(self.view_settings_panel)
            self.view_settings_panel = nil
        end
        self:onShowViewSettings()
    end
    local rows = {
        {
            icon = iname("book"),
            text = "Dictionary lookup",
            callback = function()
                UIManager:close(panel)
                self:onShowDictionaryLookup()
            end,
        },
        {
            icon = iname("a_large_small"),
            text = string.format("Font size: %d", self.font_size),
            callback = function()
                UIManager:close(panel)
                UIManager:show(SpinWidget:new{
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
                })
            end,
        },
        {
            icon = iname("heading"),
            text = string.format("Title font size: %d", self.title_font_size),
            callback = function()
                UIManager:close(panel)
                UIManager:show(SpinWidget:new{
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
                })
            end,
        },
        {
            icon = iname("type"),
            text = "Font: " .. font_label,
            callback = function()
                UIManager:close(panel)
                self:onShowFontPicker()
            end,
        },
        {
            icon = iname("move_vertical"),
            text = string.format("Line height: %s", Renderer.formatLineHeight(self.line_height)),
            callback = function()
                UIManager:close(panel)
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
        {
            icon = iname("image"),
            text = Renderer.formatShowImagesLabel(self.show_images, self:_imageStats()),
            callback = function()
                UIManager:close(panel)
                self.show_images = not self.show_images
                Renderer.saveShowImages(self.show_images)
                self:reinit()
                if self.show_images and self.callbacks.on_images_enabled then
                    self.callbacks.on_images_enabled()
                end
            end,
        },
        {
            icon = iname("align_justify"),
            text = self.justify_text and "Justify text: on" or "Justify text: off",
            callback = function()
                UIManager:close(panel)
                self.justify_text = not self.justify_text
                Renderer.saveJustifyText(self.justify_text)
                self:reinit()
            end,
        },
        {
            icon = iname("square"),
            text = "Side padding: " .. Renderer.formatPad(self.pad_side),
            callback = function()
                UIManager:close(panel)
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
        {
            icon = iname("panel_left"),
            text = "Top margin: " .. Renderer.formatPad(self.pad_top),
            callback = function()
                UIManager:close(panel)
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
        {
            icon = iname("panel_left"),
            text = "Bottom margin: " .. Renderer.formatPad(self.pad_bottom),
            callback = function()
                UIManager:close(panel)
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
    }
    if self.view_settings_panel then
        UIManager:close(self.view_settings_panel)
        self.view_settings_panel = nil
    end
    local panel = getSettingsUI().showPanel({
        title = "View settings",
        icons = icons,
        rows = rows,
        on_close = function()
            self.view_settings_panel = nil
        end,
    })
    self.view_settings_panel = panel
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

function ArticleViewer:_atLastPage()
    local hw = self.html_widget
    local box = hw and hw.htmlbox_widget
    if not box then return true end
    local page = tonumber(box.page_number) or 1
    local count = tonumber(box.page_count) or 1
    return page >= count
end

function ArticleViewer:_atFirstPage()
    local hw = self.html_widget
    local box = hw and hw.htmlbox_widget
    if not box then return true end
    local page = tonumber(box.page_number) or 1
    return page <= 1
end

function ArticleViewer:onTapNav(_, ges)
    if not ges or not ges.pos then return false end
    local right_half = ges.pos.x >= (Screen:getWidth() / 2)
    if right_half then
        if self:_atLastPage() then
            return false
        end
        return self:scroll(1)
    end
    if self:_atFirstPage() then
        return false
    end
    return self:scroll(-1)
end

function ArticleViewer:onScrollDown()
    if self:_atLastPage() then
        return false
    end
    return self:scroll(1)
end

function ArticleViewer:onScrollUp()
    if self:_atFirstPage() then
        return false
    end
    return self:scroll(-1)
end

function ArticleViewer:onSwipeNav(_, ges)
    if ges.direction == "north" then
        return self:scroll(1)
    elseif ges.direction == "south" then
        return self:scroll(-1)
    end
    return false
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

function ArticleViewer:ensureDictionary()
    if self.dictionary then return self.dictionary end
    if self._dictionary_failed then return nil end
    local ok_mod, ReaderDictionary = pcall(require, "apps/reader/modules/readerdictionary")
    if not ok_mod or not ReaderDictionary then
        self._dictionary_failed = true
        return nil
    end
    local ok_new, dict = pcall(function()
        return ReaderDictionary:new{ ui = self }
    end)
    if not ok_new or not dict then
        self._dictionary_failed = true
        return nil
    end
    self.dictionary = dict
    return self.dictionary
end

function ArticleViewer:onDictionarySelection(text, hold_duration)
    text = tostring(text or "")
    if text == "" then return end
    local dict_close_callback = function()
        local box = self.html_widget and self.html_widget.htmlbox_widget
        if box and box.scheduleClearHighlightAndRedraw then
            box:scheduleClearHighlightAndRedraw()
        end
    end
    -- Long hold (≥3s) tries Wikipedia when available; otherwise dictionary.
    if hold_duration and hold_duration >= time.s(3) then
        local ok, ReaderWikipedia = pcall(require, "apps/reader/modules/readerwikipedia")
        if ok and ReaderWikipedia then
            if not self.wikipedia then
                local ok_wiki, wiki = pcall(function()
                    return ReaderWikipedia:new{ ui = self }
                end)
                if ok_wiki and wiki then
                    self.wikipedia = wiki
                end
            end
            if self.wikipedia and self.wikipedia.onLookupWikipedia then
                pcall(function()
                    self.wikipedia:onLookupWikipedia(text, false, nil, nil, nil, dict_close_callback)
                end)
                return
            end
        end
    end
    local dict = self:ensureDictionary()
    if not dict then
        dict_close_callback()
        return
    end
    pcall(function()
        dict:onLookupWord(text, false, nil, nil, nil, dict_close_callback)
    end)
end

function ArticleViewer:onShowDictionaryLookup()
    local dict = self:ensureDictionary()
    if dict and dict.onShowDictionaryLookup then
        pcall(function() dict:onShowDictionaryLookup() end)
    end
    return true
end

function ArticleViewer:onLookupWord(word, is_sane, boxes, highlight, link, dict_close_callback)
    local dict = self:ensureDictionary()
    if dict then
        return dict:onLookupWord(word, is_sane, boxes, highlight, link, dict_close_callback)
    end
end

function ArticleViewer:_releaseHtmlWidget()
    if self._html_released then return end
    self._html_released = true
    local hw = self.html_widget
    self.html_widget = nil
    if hw and hw.free then
        pcall(function() hw:free() end)
    end
end

function ArticleViewer:_closeOverlays()
    if self.font_menu then
        pcall(function() UIManager:close(self.font_menu) end)
        self.font_menu = nil
    end
    if self.view_settings_panel then
        pcall(function() UIManager:close(self.view_settings_panel) end)
        self.view_settings_panel = nil
    end
end

function ArticleViewer:onClose()
    -- Close only the viewer — never tear down Home / the article list.
    if self._closing then return true end
    self._closing = true

    -- Stop accepting input while MuPDF / scroll handlers tear down.
    self.ges_events = nil
    self.key_events = nil

    local hw = self.html_widget
    if hw then
        local box = hw.htmlbox_widget
        if box and box.unscheduleClearHighlightAndRedraw then
            pcall(function() box:unscheduleClearHighlightAndRedraw() end)
        end
    end

    self:_closeOverlays()

    local on_detach = self.callbacks and self.callbacks.on_detach
    local on_back = self.callbacks and self.callbacks.on_back
    self.callbacks = nil

    -- Drop plugin viewer ref before UIManager:close so deferred image loads
    -- cannot reinit MuPDF on a widget that is tearing down.
    if on_detach then
        pcall(on_detach)
    end

    UIManager:close(self, "flashui")
    self:_releaseHtmlWidget()

    -- Defer list refresh until after UIManager finishes close/repaint (avoids
    -- racing home Menu paint with ScrollHtmlWidget teardown on Kindle).
    if on_back then
        UIManager:nextTick(function()
            pcall(on_back)
        end)
    end
    return true
end

function ArticleViewer:onCloseWidget()
    self:_releaseHtmlWidget()
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
