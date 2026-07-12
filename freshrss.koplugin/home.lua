-- Full-screen FreshRSS home: title bar + action buttons + article list.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local MODE_SHORT = {
    unread = "Browse",
    all = "All",
    starred = "Starred",
    feed = "Feeds",
    label = "Categories",
}

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

function Home:browseButtonLabel()
    local browse = self.plugin:browseState()
    return MODE_SHORT[browse.mode or "unread"] or "Browse"
end

function Home:buildLayout()
    local plugin = self.plugin
    local width = self.dimen.w

    self.title_bar = TitleBar:new{
        width = width,
        fullscreen = true,
        align = "center",
        with_bottom_line = true,
        title = plugin:menuTitle(),
        subtitle = plugin:menuSubtitle(),
        title_multilines = true,
        left_icon = plugin.icons:name("refresh"),
        left_icon_size_ratio = 1,
        left_icon_tap_callback = function()
            plugin:requestSync()
        end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    self.action_buttons = ButtonTable:new{
        width = width,
        buttons = {
            {
                {
                    text = self:browseButtonLabel(),
                    callback = function() plugin:showBrowsePicker() end,
                },
                {
                    text = "Mark all",
                    callback = function() plugin:confirmMarkAllRead() end,
                },
                {
                    text = "Settings",
                    callback = function() plugin:showSettingsMenu() end,
                },
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
    self.list = Menu:new{
        title = "",
        no_title = true,
        is_popout = false,
        is_borderless = true,
        width = width,
        height = list_height,
        multilines_show_more_text = true,
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

-- Rebuild chrome after browse-mode / settings changes so button labels stay correct.
function Home:reopen()
    local plugin = self.plugin
    UIManager:close(self)
    plugin.home = nil
    plugin.menu = nil
    plugin:showCached()
end

function Home:updateList()
    if self.list then
        self.list:switchItemTable("", self.plugin:buildItemTable())
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

return Home
