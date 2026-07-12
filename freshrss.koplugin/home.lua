-- Full-screen FreshRSS home: TitleBar + actions/favorites row + article list.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")
local ListMenu = dofile(plugin_dir .. "/list_menu.lua")
local FavCategories = dofile(plugin_dir .. "/fav_categories.lua")
local SettingsUI = dofile(plugin_dir .. "/settings_ui.lua")
local Status = dofile(plugin_dir .. "/ui_status.lua")

local Home = InputContainer:extend{
    name = "freshrss_home",
    covers_fullscreen = true,
    plugin = nil,
}

---Empty input tables on widget subtrees (nil ges_events crashes InputContainer).
local function neutralizeInputTree(widget, depth)
    if not widget or (depth or 0) > 32 then return end
    depth = (depth or 0) + 1
    if widget.handleEvent then
        widget.key_events = {}
        widget.ges_events = {}
    end
    if widget.skip_paint ~= nil then
        widget.skip_paint = true
    end
    local n = #(widget or {})
    for i = 1, n do
        neutralizeInputTree(widget[i], depth)
    end
end

local CategoryChip = InputContainer:extend{
    name = "freshrss_category_chip",
    fav = nil,
    selected = false,
    icons = nil,
    callback = nil,
    hold_callback = nil,
    show_parent = nil,
}

function CategoryChip:init()
    local side = Screen:scaleBySize(30)
    local pad = Size.padding.tiny
    local inner
    local icon_key = self.fav and self.fav.icon
    if icon_key and self.icons and self.icons:has(icon_key) then
        local IconWidget = require("ui/widget/iconwidget")
        inner = IconWidget:new{
            icon = self.icons:name(icon_key),
            width = side - 4,
            height = side - 4,
        }
    else
        local name = FavCategories.labelDisplayName(self.fav and self.fav.id)
        inner = SettingsUI.letterTile(FavCategories.twoLetters(name), { size = side - 4 })
    end
    self.frame = FrameContainer:new{
        bordersize = self.selected and Size.border.thick or Size.border.thin,
        padding = pad,
        margin = Size.margin.tiny,
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.default,
        inner,
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        TapChip = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldChip = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function CategoryChip:onTapChip()
    if self.callback then self.callback() end
    return true
end

function CategoryChip:onHoldChip()
    if self.hold_callback then self.hold_callback() end
    return true
end

function Home:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self:buildLayout()
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
end

function Home:_buildHeader(width)
    local plugin = self.plugin
    local icons = plugin.icons
    self.title_bar = TitleBar:new{
        width = width,
        fullscreen = true,
        align = "center",
        with_bottom_line = true,
        title = plugin:menuTitle(),
        subtitle = nil,
        title_multilines = false,
        title_shrink_font_to_fit = true,
        left_icon = icons:name("freshrss"),
        left_icon_size_ratio = 0.7,
        left_icon_tap_callback = function() plugin:requestSync() end,
        left_icon_allow_flash = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    return self.title_bar
end

function Home:_actionChip(icon_key, callback)
    local plugin = self.plugin
    local icons = plugin.icons
    local btn = IconButton:new{
        icon = icons:name(icon_key),
        width = Screen:scaleBySize(26),
        height = Screen:scaleBySize(26),
        padding = Size.padding.tiny,
        callback = callback,
        allow_flash = true,
        show_parent = self,
    }
    return FrameContainer:new{
        bordersize = Size.border.thin,
        padding = Size.padding.tiny,
        margin = Size.margin.tiny,
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.default,
        btn,
    }
end

function Home:_buildFavoritesRow(width)
    local plugin = self.plugin
    local icons = plugin.icons
    local browse = plugin:browseState()
    local favs = FavCategories.read(plugin.settings)
    local chips = HorizontalGroup:new{}
    local function addChip(widget)
        table.insert(chips, widget)
        table.insert(chips, HorizontalSpan:new{ width = Size.span.horizontal_small })
    end

    -- Browse / Mark all / Settings live on the favorites row (not the TitleBar).
    addChip(self:_actionChip("list_filter", function() plugin:showBrowsePicker() end))
    addChip(self:_actionChip("check_circle", function() plugin:confirmMarkAllRead() end))
    addChip(self:_actionChip("settings", function() plugin:showSettingsMenu() end))

    local sep_h = Screen:scaleBySize(28)
    table.insert(chips, LineWidget:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        dimen = Geom:new{ w = Size.line.medium, h = sep_h },
    })
    table.insert(chips, HorizontalSpan:new{ width = Size.span.horizontal_small })

    -- All-articles chip (layout-list) before favorite categories.
    local all_selected = browse.mode == "all"
    addChip(FrameContainer:new{
        bordersize = all_selected and Size.border.thick or Size.border.thin,
        padding = Size.padding.tiny,
        margin = Size.margin.tiny,
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.default,
        IconButton:new{
            icon = icons:name("layout_list"),
            width = Screen:scaleBySize(26),
            height = Screen:scaleBySize(26),
            padding = Size.padding.tiny,
            callback = function()
                plugin:setBrowseState({ mode = "all" })
                plugin:showCached(true)
            end,
            allow_flash = true,
            show_parent = self,
        },
    })

    for _, fav in ipairs(favs) do
        local selected = browse.mode == "label" and browse.label == fav.id
        addChip(CategoryChip:new{
            fav = fav,
            selected = selected,
            icons = icons,
            show_parent = self,
            callback = function()
                plugin:setBrowseState({ mode = "label", label = fav.id })
                plugin:showCached(true)
            end,
            hold_callback = function()
                plugin:showCategoryIconPicker(fav.id)
            end,
        })
    end

    local plus = IconButton:new{
        icon = icons:name("plus"),
        width = Screen:scaleBySize(26),
        height = Screen:scaleBySize(26),
        padding = Size.padding.tiny,
        callback = function() plugin:showFavoriteCategoryPicker() end,
        hold_callback = function() plugin:showFavoriteCategoryPicker() end,
        allow_flash = true,
        show_parent = self,
    }
    addChip(FrameContainer:new{
        bordersize = Size.border.thin,
        padding = Size.padding.tiny,
        margin = Size.margin.tiny,
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.default,
        plus,
    })

    self.favorites_row = FrameContainer:new{
        bordersize = 0,
        padding = Size.padding.small,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = width,
        VerticalGroup:new{
            align = "left",
            chips,
            VerticalSpan:new{ width = Size.padding.tiny },
            LineWidget:new{
                background = Blitbuffer.COLOR_DARK_GRAY,
                dimen = Geom:new{ w = width - Size.padding.small * 2, h = Size.line.thin },
            },
        },
    }
    return self.favorites_row
end

function Home:buildLayout()
    local plugin = self.plugin
    local width = self.dimen.w

    local header = self:_buildHeader(width)
    local fav_row = self:_buildFavoritesRow(width)

    local chrome_h = header:getSize().h + fav_row:getSize().h
    local list_height = self.dimen.h - chrome_h
    if list_height < Screen:scaleBySize(200) then
        list_height = Screen:scaleBySize(200)
    end

    if plugin.list_fonts then
        plugin.list_fonts.apply()
    end
    local list_font_size = 20
    if plugin.list_fonts then
        list_font_size = plugin.list_fonts.readFontSize()
    end
    self.list = ListMenu:new{
        title = "",
        no_title = true,
        is_popout = false,
        is_borderless = true,
        width = width,
        height = list_height,
        multilines_show_more_text = false,
        multilines_forced = true,
        single_line = false,
        is_enable_shortcut = false,
        items_font_size = list_font_size,
        items_mandatory_font_size = math.max(12, list_font_size - 4),
        item_table = plugin:buildItemTable(),
        list_fonts = plugin.list_fonts,
        show_parent = self,
        close_callback = nil,
    }
    if self.list.key_events then
        self.list.key_events.Close = nil
    end

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        width = width,
        height = self.dimen.h,
        VerticalGroup:new{
            align = "left",
            header,
            fav_row,
            self.list,
        },
    }
end

function Home:reopen()
    local plugin = self.plugin
    UIManager:close(self)
    plugin.home = nil
    plugin.menu = nil
    plugin._list_restore = nil
    plugin:showCached()
end

function Home:updateList()
    if self.plugin and self.plugin.list_fonts then
        self.plugin.list_fonts.apply()
    end
    if self.list then
        if self.plugin and self.plugin.list_fonts then
            self.list.items_font_size = self.plugin.list_fonts.readFontSize()
        end
        local items = self.plugin:buildItemTable()
        local restore = self.plugin._list_restore
        if restore and restore.article_id then
            self.list:switchItemTable("", items, nil, { article_id = restore.article_id })
        elseif restore and restore.page then
            self.list:switchItemTable("", items)
            local page = tonumber(restore.page) or 1
            local max_page = tonumber(self.list.page_num) or 1
            if page > max_page then page = max_page end
            if page < 1 then page = 1 end
            if self.list.onGotoPage then
                self.list:onGotoPage(page)
            end
        else
            self.list:switchItemTable("", items)
        end
    end
    UIManager:setDirty(self, "ui")
end

function Home:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
    return true
end

function Home:onClose()
    if self._closing then return true end
    self._closing = true

    -- Stop accepting input while the nested Menu tears down (empty tables, not
    -- nil — InputContainer pairs() key_events / ges_events on every gesture).
    neutralizeInputTree(self)

    local plugin = self.plugin
    self._close_plugin = plugin
    self.plugin = nil

    if plugin then
        pcall(function() plugin:closeHomeOverlays() end)
        pcall(function() Status:close() end)
        -- Restore Gujarati fallback injection before underlying UI repaints.
        -- smallinfofont is never remapped globally (list_menu scopes Latin font).
        if plugin.list_fonts then
            pcall(function() plugin.list_fonts.restore() end)
        end
    end

    UIManager:close(self, "flashui")

    if plugin then
        UIManager:nextTick(function()
            pcall(function() plugin:onHomeClosed() end)
        end)
    end
    return true
end

return Home
