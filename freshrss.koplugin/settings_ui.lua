-- Shared icon+text settings chrome for FreshRSS (hub, submenus, view settings).
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local SettingsUI = {}

SettingsUI.ICON_PAGE_SIZE = 8

local function iconSize()
    return Screen:scaleBySize(22)
end

---Square tile with two letters (category chip fallback).
function SettingsUI.letterTile(letters, opts)
    opts = opts or {}
    local side = opts.size or Screen:scaleBySize(28)
    local face = Font:getFace("xx_smallinfofont", opts.font_size or 12)
        or Font:getFace("x_smallinfofont")
        or Font:getFace("cfont")
    local text = TextWidget:new{
        text = tostring(letters or "??"),
        face = face,
        bold = true,
    }
    return FrameContainer:new{
        bordersize = Size.border.thin,
        padding = Size.padding.tiny,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = side,
        height = side,
        CenterContainer:new{
            dimen = Geom:new{ w = side - 2 * Size.border.thin, h = side - 2 * Size.border.thin },
            text,
        },
    }
end

local IconTextRow = InputContainer:extend{
    name = "freshrss_settings_row",
    width = nil,
    icon = nil,
    text = nil,
    callback = nil,
    hold_callback = nil,
    show_parent = nil,
}

function IconTextRow:init()
    self.width = self.width or Screen:getWidth()
    local pad = Size.padding.large
    local size = iconSize()
    local icon_widget
    if self.icon then
        icon_widget = IconWidget:new{
            icon = self.icon,
            width = size,
            height = size,
        }
    else
        icon_widget = SettingsUI.letterTile(self.letters or "??", { size = size })
    end
    local label = TextWidget:new{
        text = self.text or "",
        face = Font:getFace("smallinfofont"),
        max_width = self.width - size - pad * 3,
    }
    self.row = FrameContainer:new{
        bordersize = 0,
        padding = pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = self.width,
        HorizontalGroup:new{
            icon_widget,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            label,
        },
    }
    self[1] = self.row
    self.dimen = self.row:getSize()
    self.dimen.w = self.width
    self.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
        HoldSelect = {
            GestureRange:new{ ges = "hold", range = self.dimen },
        },
    }
end

function IconTextRow:onTapSelect()
    if self.callback then self.callback() end
    return true
end

function IconTextRow:onHoldSelect()
    if self.hold_callback then
        self.hold_callback()
        return true
    end
end

function SettingsUI.iconTextRow(opts)
    return IconTextRow:new(opts)
end

local SettingsPanel = InputContainer:extend{
    name = "freshrss_settings_panel",
    covers_fullscreen = true,
    title = "Settings",
    rows = nil,
    on_close = nil,
    icons = nil,
}

function SettingsPanel:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    local width = self.dimen.w
    self.title_bar = TitleBar:new{
        width = width,
        fullscreen = true,
        align = "center",
        with_bottom_line = true,
        title = self.title or "Settings",
        title_face = Font:getFace("x_smalltfont"),
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local items = VerticalGroup:new{ align = "left" }
    local rows = self.rows or {}
    for i, row in ipairs(rows) do
        local widget
        if row.widget then
            widget = row.widget
        else
            widget = SettingsUI.iconTextRow({
                width = width,
                icon = row.icon,
                letters = row.letters,
                text = row.text,
                callback = row.callback,
                hold_callback = row.hold_callback,
                show_parent = self,
            })
        end
        table.insert(items, widget)
        if i < #rows then
            table.insert(items, LineWidget:new{
                background = Blitbuffer.COLOR_DARK_GRAY,
                dimen = Geom:new{ w = width, h = Size.line.thin },
            })
        end
    end
    if #rows == 0 then
        table.insert(items, VerticalSpan:new{ width = Size.padding.large })
        table.insert(items, TextWidget:new{
            text = "No items",
            face = Font:getFace("smallinfofont"),
        })
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
            items,
        },
    }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
end

function SettingsPanel:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

function SettingsPanel:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

function SettingsUI.showPanel(opts)
    local panel = SettingsPanel:new(opts)
    UIManager:show(panel, "ui")
    return panel
end

---Slice rows for a 1-based page (testable helper).
function SettingsUI.sliceRows(rows, page, page_size)
    rows = rows or {}
    page = tonumber(page) or 1
    page_size = tonumber(page_size) or SettingsUI.ICON_PAGE_SIZE
    if page < 1 then page = 1 end
    if page_size < 1 then page_size = 1 end
    local page_count = math.max(1, math.ceil(#rows / page_size))
    if page > page_count then page = page_count end
    local start_i = (page - 1) * page_size + 1
    local end_i = math.min(#rows, start_i + page_size - 1)
    local slice = {}
    for i = start_i, end_i do
        table.insert(slice, rows[i])
    end
    return slice, page, page_count
end

local function pagerBar(opts)
    opts = opts or {}
    local width = opts.width or Screen:getWidth()
    local page = tonumber(opts.page) or 1
    local page_count = tonumber(opts.page_count) or 1
    local icons = opts.icons
    local IconButton = require("ui/widget/iconbutton")
    local prev_btn = IconButton:new{
        icon = icons and icons:name("chevron_left") or "chevron.left",
        width = Screen:scaleBySize(26),
        height = Screen:scaleBySize(26),
        padding = Size.padding.tiny,
        enabled = page > 1,
        callback = opts.on_prev,
        allow_flash = true,
        show_parent = opts.show_parent,
    }
    local next_btn = IconButton:new{
        icon = icons and icons:name("chevron_right") or "chevron.right",
        width = Screen:scaleBySize(26),
        height = Screen:scaleBySize(26),
        padding = Size.padding.tiny,
        enabled = page < page_count,
        callback = opts.on_next,
        allow_flash = true,
        show_parent = opts.show_parent,
    }
    local label = TextWidget:new{
        text = string.format("%d / %d", page, page_count),
        face = Font:getFace("smallinfofont"),
    }
    local row = HorizontalGroup:new{
        CenterContainer:new{
            dimen = Geom:new{ w = math.floor(width / 3), h = Screen:scaleBySize(30) },
            prev_btn,
        },
        CenterContainer:new{
            dimen = Geom:new{ w = math.floor(width / 3), h = Screen:scaleBySize(30) },
            label,
        },
        CenterContainer:new{
            dimen = Geom:new{ w = math.floor(width / 3), h = Screen:scaleBySize(30) },
            next_btn,
        },
    }
    return FrameContainer:new{
        bordersize = 0,
        padding = Size.padding.large,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = width,
        row,
    }
end

function SettingsUI.showPaginatedPanel(opts)
    opts = opts or {}
    local all_rows = opts.rows or {}
    local page_size = opts.page_size or SettingsUI.ICON_PAGE_SIZE
    local icons = opts.icons
    local title_base = opts.title or "Settings"
    local on_close = opts.on_close
    local page = 1
    local panel_ref = { panel = nil }

    local function rebuild()
        if panel_ref.panel then
            UIManager:close(panel_ref.panel)
            panel_ref.panel = nil
        end
        local slice, cur_page, page_count = SettingsUI.sliceRows(all_rows, page, page_size)
        page = cur_page
        local rows = {}
        for _, row in ipairs(slice) do
            table.insert(rows, row)
        end
        if page_count > 1 then
            table.insert(rows, {
                widget = pagerBar({
                    width = Screen:getWidth(),
                    page = cur_page,
                    page_count = page_count,
                    icons = icons,
                    show_parent = panel_ref.panel,
                    on_prev = function()
                        if page > 1 then
                            page = page - 1
                            rebuild()
                        end
                    end,
                    on_next = function()
                        if page < page_count then
                            page = page + 1
                            rebuild()
                        end
                    end,
                }),
            })
        end
        local title = title_base
        if page_count > 1 then
            title = string.format("%s · %d/%d", title_base, cur_page, page_count)
        end
        panel_ref.panel = SettingsPanel:new{
            title = title,
            icons = icons,
            rows = rows,
            on_close = on_close,
        }
        if opts.set_panel then
            opts.set_panel(panel_ref.panel)
        end
        UIManager:show(panel_ref.panel, "ui")
    end

    rebuild()
    return panel_ref.panel
end

SettingsUI.IconTextRow = IconTextRow
SettingsUI.SettingsPanel = SettingsPanel

return SettingsUI
