-- Two-line FreshRSS article list row: title (wrap) + compact feed · time subtitle.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local ListMenuItem = InputContainer:extend{
    font = "smallinfofont",
    infont = "infont",
    linesize = Size.line.medium,
    single_line = false,
    multilines_forced = false,
}

function ListMenuItem:getGesPosition(ges)
    local dimen = self[1].dimen
    return {
        x = (ges.pos.x - dimen.x) / dimen.w,
        y = (ges.pos.y - dimen.y) / dimen.h,
    }
end

function ListMenuItem:onTapSelect(arg, ges)
    if not self[1].dimen then return end
    local pos = self:getGesPosition(ges)
    if G_reader_settings:isFalse("flash_ui") then
        self.menu:onMenuSelect(self.entry, pos)
    else
        self[1].invert = true
        UIManager:widgetInvert(self[1], self[1].dimen.x, self[1].dimen.y)
        UIManager:setDirty(nil, "fast", self[1].dimen)
        UIManager:forceRePaint()
        UIManager:yieldToEPDC()
        self[1].invert = false
        UIManager:widgetInvert(self[1], self[1].dimen.x, self[1].dimen.y)
        UIManager:setDirty(nil, "ui", self[1].dimen)
        self.menu:onMenuSelect(self.entry, pos)
        UIManager:forceRePaint()
    end
    return true
end

function ListMenuItem:onHoldSelect(arg, ges)
    if not self[1].dimen then return end
    local pos = self:getGesPosition(ges)
    if G_reader_settings:isFalse("flash_ui") then
        self.menu:onMenuHold(self.entry, pos)
    else
        self[1].invert = true
        UIManager:widgetInvert(self[1], self[1].dimen.x, self[1].dimen.y)
        UIManager:setDirty(nil, "fast", self[1].dimen)
        UIManager:forceRePaint()
        UIManager:yieldToEPDC()
        self[1].invert = false
        UIManager:widgetInvert(self[1], self[1].dimen.x, self[1].dimen.y)
        UIManager:setDirty(nil, "ui", self[1].dimen)
        self.menu:onMenuHold(self.entry, pos)
        UIManager:forceRePaint()
    end
    return true
end

function ListMenuItem:init()
    self.content_width = self.dimen.w - 2 * Size.padding.fullscreen

    self.ges_events = {
        TapSelect = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
        HoldSelect = {
            GestureRange:new{
                ges = self.handle_hold_on_hold_release and "hold_release" or "hold",
                range = self.dimen,
            },
        },
    }

    local max_item_height = self.dimen.h - 2 * self.linesize
    local max_font_size = TextBoxWidget:getFontSizeToFitHeight(max_item_height, 1)
    if self.font_size > max_font_size then
        self.font_size = max_font_size
    end
    if self.infont_size > max_font_size then
        self.infont_size = max_font_size
    end

    self.face = Font:getFace(self.font, self.font_size)
    self.info_face = Font:getFace(self.infont, self.infont_size)

    local mandatory = self.mandatory_func and self.mandatory_func() or self.mandatory
    local mandatory_dim = self.mandatory_dim_func and self.mandatory_dim_func() or self.mandatory_dim
    local text_mandatory_padding = 0
    if mandatory then
        text_mandatory_padding = Size.span.horizontal_default
    end
    local mandatory_widget = TextWidget:new{
        text = mandatory or "",
        face = self.info_face,
        bold = self.bold,
        fgcolor = mandatory_dim and Blitbuffer.COLOR_DARK_GRAY or nil,
    }
    local mandatory_w = mandatory_widget:getWidth()
    local available_width = self.content_width - text_mandatory_padding - mandatory_w

    local subtitle = self.subtitle
    if subtitle == nil and self.entry and self.entry.subtitle then
        subtitle = self.entry.subtitle
    end
    subtitle = subtitle and tostring(subtitle) or nil
    if subtitle == "" then subtitle = nil end

    local item_name
    local text = tostring(self.text or "")

    if subtitle then
        local subtitle_gap = Screen:scaleBySize(1)
        local subtitle_widget = TextWidget:new{
            text = subtitle,
            face = self.info_face,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        local subtitle_h = subtitle_widget:getSize().h
        local title_max_h = max_item_height - subtitle_h - subtitle_gap
        if title_max_h < subtitle_h then
            title_max_h = subtitle_h
        end
        item_name = VerticalGroup:new{
            align = "left",
            TextBoxWidget:new{
                text = text,
                face = self.face,
                width = available_width,
                height = title_max_h,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
                alignment = "left",
                bold = self.bold,
                fgcolor = self.dim and Blitbuffer.COLOR_DARK_GRAY or nil,
            },
            VerticalSpan:new{ width = subtitle_gap },
            subtitle_widget,
        }
    elseif self.single_line then
        item_name = TextWidget:new{
            text = text,
            face = self.face,
            bold = self.bold,
            truncate_left = self.truncate_left,
            fgcolor = self.dim and Blitbuffer.COLOR_DARK_GRAY or nil,
        }
        if item_name:getWidth() > available_width then
            item_name:setMaxWidth(available_width)
        end
    else
        item_name = TextBoxWidget:new{
            text = text,
            face = self.face,
            width = available_width,
            height = self.entry.height and (self.entry.height - 2 * Size.span.vertical_default - self.linesize) or max_item_height,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            alignment = "left",
            bold = self.bold,
            fgcolor = self.dim and Blitbuffer.COLOR_DARK_GRAY or nil,
        }
    end

    local text_container = LeftContainer:new{
        dimen = Geom:new{ w = self.content_width, h = self.dimen.h },
        item_name,
    }
    local mandatory_container = RightContainer:new{
        dimen = Geom:new{ w = self.content_width, h = self.dimen.h },
        mandatory_widget,
    }

    self._underline_container = UnderlineContainer:new{
        color = self.line_color,
        linesize = self.linesize,
        vertical_align = "center",
        padding = 0,
        dimen = Geom:new{
            x = 0, y = 0,
            w = self.content_width,
            h = self.dimen.h,
        },
        OverlapGroup:new{
            dimen = Geom:new{ w = self.content_width, h = self.dimen.h },
            text_container,
            mandatory_container,
        },
    }

    local hgroup = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = self.items_padding or Size.padding.fullscreen },
        self._underline_container,
        HorizontalSpan:new{ width = Size.padding.fullscreen },
    }

    self[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        hgroup,
    }
end

function ListMenuItem:onFocus()
    self._underline_container.color = Blitbuffer.COLOR_BLACK
    return true
end

function ListMenuItem:onUnfocus()
    self._underline_container.color = self.line_color
    return true
end

return ListMenuItem
