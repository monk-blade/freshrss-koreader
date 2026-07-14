-- Thin top-of-screen sync progress strip (text + ProgressWidget + cancel).
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local IconWidget = require("ui/widget/iconwidget")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

local StatusStrip = WidgetContainer:extend{
    name = "freshrss_status_strip",
}

function StatusStrip:init()
    self.width = Screen:getWidth()
    self.bar_height = Screen:scaleBySize(8)
    self.padding = Size.padding.small
    self.label = TextWidget:new{
        text = self.text or "Syncing…",
        face = Font:getFace("smallinfofont"),
        max_width = self.width - Screen:scaleBySize(96),
    }
    self.progress = ProgressWidget:new{
        width = self.width - 2 * self.padding,
        height = self.bar_height,
        percentage = self.percentage or 0,
        bordercolor = Blitbuffer.COLOR_BLACK,
        fillcolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_WHITE,
    }
    local header_children = {
        self.icon_widget or TextWidget:new{ text = "", face = Font:getFace("smallinfofont") },
        self.label,
    }
    if self.on_cancel then
        local cancel_size = Screen:scaleBySize(20)
        table.insert(header_children, HorizontalSpan:new{ width = Size.span.horizontal_small })
        table.insert(header_children, IconButton:new{
            icon = "close",
            width = cancel_size,
            height = cancel_size,
            padding = Size.padding.tiny,
            callback = function()
                if self.on_cancel then self.on_cancel() end
            end,
            allow_flash = true,
            show_parent = self,
        })
    end
    local header = HorizontalGroup:new(header_children)
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.thin,
        padding = self.padding,
        width = self.width,
        VerticalGroup:new{
            align = "left",
            header,
            self.progress,
        },
    }
    self.dimen = Geom:new{
        x = 0,
        y = 0,
        w = self.width,
        h = self[1]:getSize().h,
    }
end

function StatusStrip:setProgress(text, percentage)
    self.label:setText(text or self.label.text)
    self.progress:setPercentage(math.max(0, math.min(1, percentage or 0)))
    UIManager:setDirty(self, "ui", self.dimen)
end

local Status = {
    strip = nil,
    icons = nil,
    on_cancel = nil,
}

function Status:setIcons(icons)
    self.icons = icons
end

function Status:show(text, percentage, on_cancel)
    self:close()
    self.on_cancel = on_cancel
    local icon_widget
    if self.icons then
        local path = self.icons:path("refresh")
        if path then
            icon_widget = IconWidget:new{
                file = path,
                width = Screen:scaleBySize(18),
                height = Screen:scaleBySize(18),
                alpha = true,
            }
        end
    end
    self.strip = StatusStrip:new{
        text = text or "Syncing FreshRSS…",
        percentage = percentage or 0,
        icon_widget = icon_widget,
        on_cancel = on_cancel,
    }
    UIManager:show(self.strip)
    UIManager:forceRePaint()
end

function Status:update(text, percentage)
    if not self.strip then
        self:show(text, percentage, self.on_cancel)
        return
    end
    self.strip:setProgress(text, percentage)
    UIManager:forceRePaint()
end

function Status:close()
    if self.strip then
        UIManager:close(self.strip)
        self.strip = nil
    end
    self.on_cancel = nil
end

return Status
