-- Full-screen FreshRSS home: title bar + action buttons + article list.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local Home = InputContainer:extend{
    name = "freshrss_home",
    covers_fullscreen = true,
    plugin = nil,
}

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

function Home:buildLayout()
    local plugin = self.plugin
    local width = self.dimen.w

    -- Brand mark left (tap = sync). Compact TitleBar padding for e-ink density.
    self.title_bar = TitleBar:new{
        width = width,
        fullscreen = true,
        align = "center",
        with_bottom_line = true,
        title = plugin:menuTitle(),
        subtitle = plugin:menuSubtitle(),
        title_face = Font:getFace("x_smalltfont"),
        title_multilines = false,
        title_top_padding = Size.padding.small,
        title_subtitle_v_padding = Screen:scaleBySize(1),
        bottom_v_padding = Size.padding.small,
        left_icon = plugin.icons:name("freshrss"),
        left_icon_size_ratio = 0.85,
        left_icon_allow_flash = true,
        left_icon_tap_callback = function()
            plugin:requestSync()
        end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    -- Icon-only action bar (KOReader Button is icon XOR text). Browse mode
    -- stays visible in the title; icons keep the bar compact on e-ink.
    local icons = plugin.icons
    local action_icon_size = Screen:scaleBySize(22)
    self.action_buttons = ButtonTable:new{
        width = width,
        buttons = {
            {
                icons:button("list_filter", {
                    size = action_icon_size,
                    callback = function() plugin:showBrowsePicker() end,
                }),
                icons:button("check_circle", {
                    size = action_icon_size,
                    callback = function() plugin:confirmMarkAllRead() end,
                }),
                icons:button("settings", {
                    size = action_icon_size,
                    callback = function() plugin:showSettingsMenu() end,
                }),
            },
        },
        zero_sep = true,
        show_parent = self,
    }

    local list_height = self.dimen.h
        - self.title_bar:getHeight()
        - self.action_buttons:getSize().h
    if list_height < Screen:scaleBySize(200) then
        list_height = Screen:scaleBySize(200)
    end

    -- Nested Menu must not own Back / close: only Home TitleBar X (and Home Back) exits.
    -- MenuItem always uses Font face "smallinfofont"; ListFonts remaps that + Gujarati fallback.
    if plugin.list_fonts then
        plugin.list_fonts.apply()
    end
    local list_font_size = 20
    if plugin.list_fonts then
        list_font_size = plugin.list_fonts.readFontSize()
    end
    self.list = Menu:new{
        title = "",
        no_title = true,
        is_popout = false,
        is_borderless = true,
        width = width,
        height = list_height,
        -- Single-line rows keep the list denser (Gujarati titles truncate instead of wrapping).
        multilines_show_more_text = false,
        -- Hide Q/W/E… shortcut letter boxes (default when Device:hasKeyboard()).
        is_enable_shortcut = false,
        items_font_size = list_font_size,
        item_table = plugin:buildItemTable(),
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
            self.title_bar,
            self.action_buttons,
            self.list,
        },
    }
end

-- Rebuild chrome after browse-mode / settings changes.
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
    if self.plugin then
        self.plugin:onHomeClosed()
    end
    UIManager:close(self)
    return true
end

function Home:onCloseWidget()
    -- UIManager:close sends CloseWidget (not Close); restore Menu face remap here.
    if self.plugin and self.plugin.list_fonts then
        self.plugin.list_fonts.restore()
    end
end

return Home
