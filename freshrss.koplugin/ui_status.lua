-- Thin top-of-screen sync progress strip (text + ProgressWidget).
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
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
        max_width = self.width - Screen:scaleBySize(48),
    }
    self.progress = ProgressWidget:new{
        width = self.width - 2 * self.padding,
        height = self.bar_height,
        percentage = self.percentage or 0,
        bordercolor = Blitbuffer.COLOR_BLACK,
        fillcolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_WHITE,
    }
    local header = HorizontalGroup:new{
        self.icon_widget or TextWidget:new{ text = "", face = Font:getFace("smallinfofont") },
        self.label,
    }
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
}

function Status:setIcons(icons)
    self.icons = icons
end

function Status:show(text, percentage)
    self:close()
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
    }
    UIManager:show(self.strip)
    UIManager:forceRePaint()
end

function Status:update(text, percentage)
    if not self.strip then
        self:show(text, percentage)
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
end

return Status
