-- FreshRSS article list Menu: apply list Latin font without remapping global
-- Font.fontmap.smallinfofont (CoverBrowser/bookshelf use that key on exit).
local BD = require("ui/bidi")
local Button = require("ui/widget/button")
local Device = require("device")
local Geom = require("ui/geometry")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")
local ListMenuItem = dofile(plugin_dir .. "/list_menu_item.lua")

local ListMenu = Menu:extend{
    name = "freshrss_article_list",
    list_fonts = nil,
}

---Compact page footer: smaller chevrons + less reserved height than stock Menu.
function ListMenu:init()
    local chev_size = Screen:scaleBySize(22)
    local pad = Size.padding.tiny

    local function pageButton(icon, callback)
        return Button:new{
            icon = icon,
            callback = callback,
            bordersize = 0,
            padding = pad,
            width = chev_size,
            height = chev_size,
            icon_width = chev_size,
            icon_height = chev_size,
            show_parent = self.show_parent or self,
        }
    end

    local chevron_left = "chevron.left"
    local chevron_right = "chevron.right"
    local chevron_first = "chevron.first"
    local chevron_last = "chevron.last"
    if BD.mirroredUILayout() then
        chevron_left, chevron_right = chevron_right, chevron_left
        chevron_first, chevron_last = chevron_last, chevron_first
    end

    self.page_info_left_chev = pageButton(chevron_left, function() self:onPrevPage() end)
    self.page_info_right_chev = pageButton(chevron_right, function() self:onNextPage() end)
    self.page_info_first_chev = pageButton(chevron_first, function() self:onFirstPage() end)
    self.page_info_last_chev = pageButton(chevron_last, function() self:onLastPage() end)
    self.page_info_spacer = HorizontalSpan:new{ width = Screen:scaleBySize(12) }

    Menu.init(self)

    if self.page_info_text then
        self.page_info_text.padding = pad
        if self.page_info_text.update then
            self.page_info_text:update()
        end
    end
end

function ListMenu:_recalculateDimen(no_recalculate_dimen)
    local perpage = self.items_per_page
        or G_reader_settings:readSetting("items_per_page")
        or self.items_per_page_default
    local font_size = self.items_font_size
        or G_reader_settings:readSetting("items_font_size")
        or Menu.getItemFontSize(perpage)
    if self.perpage ~= perpage or self.font_size ~= font_size then
        self.perpage = perpage
        self.font_size = font_size
        no_recalculate_dimen = false
    end

    if no_recalculate_dimen then return end

    local top_height = 0
    if self.title_bar and not self.no_title then
        top_height = self.title_bar:getHeight()
    end
    local bottom_height = 0
    if self.page_return_arrow and self.page_info_text then
        bottom_height = math.max(
            self.page_return_arrow:getSize().h,
            self.page_info_text:getSize().h
        ) + Size.padding.tiny
    end
    self.available_height = self.inner_dimen.h - top_height - bottom_height
    self.item_dimen = Geom:new{
        x = 0, y = 0,
        w = self.inner_dimen.w,
        h = math.floor(self.available_height / perpage),
    }

    if self.items_max_lines then
        self:setupItemHeights()
    end

    self.page_num = self:getPageNumber(#self.item_table)
    if self.page > self.page_num then
        self.page = self.page_num
    end
end

---Build rows with ListMenuItem (title + subtitle) while scoping list Latin face.
function ListMenu:updateItems(select_number, no_recalculate_dimen)
    local Font = require("ui/font")
    local saved_smallinfo = Font.fontmap.smallinfofont
    local latin
    if self.list_fonts then
        latin = self.list_fonts.resolveLatinFont()
        if latin and type(latin) == "string" and latin ~= "" then
            local f = io.open(latin, "rb")
            if f then
                f:close()
                Font.fontmap.smallinfofont = latin
            end
        end
    end

    local ok, err = pcall(function()
        local old_dimen = self.dimen and self.dimen:copy()
        self.layout = {}
        self.item_group:clear()
        self.page_info:resetLayout()
        self.return_button:resetLayout()
        self.content_group:resetLayout()
        self:_recalculateDimen(no_recalculate_dimen)

        local items_nb
        local idx_offset, multilines_show_more_text
        if self.items_max_lines then
            items_nb = #self.page_items[self.page]
        else
            items_nb = self.perpage
            idx_offset = (self.page - 1) * items_nb
            multilines_show_more_text = self.multilines_show_more_text
            if multilines_show_more_text == nil then
                multilines_show_more_text = G_reader_settings:isTrue("items_multilines_show_more_text")
            end
        end

        for idx = 1, items_nb do
            local index = self.items_max_lines and self.page_items[self.page][idx] or idx_offset + idx
            local item = self.item_table[index]
            if item == nil then break end
            item.idx = index
            if index == self.itemnumber then
                select_number = idx
            end
            local item_shortcut, shortcut_style
            if self.is_enable_shortcut then
                item_shortcut = self.item_shortcuts[idx]
                shortcut_style = (idx < 11 or idx > 20) and "square" or "grey_square"
            end
            if self.items_max_lines then
                self.item_dimen.h = item.height
            end
            local item_tmp = ListMenuItem:new{
                idx = index,
                show_parent = self.show_parent,
                text = Menu.getMenuText(item),
                subtitle = item.subtitle,
                mandatory = item.mandatory,
                mandatory_func = item.mandatory_func,
                mandatory_dim = item.mandatory_dim or item.dim,
                mandatory_dim_func = item.mandatory_dim_func,
                bold = self.item_table.current == index or item.bold == true,
                dim = item.dim,
                font_size = self.font_size,
                infont_size = self.items_mandatory_font_size or (self.font_size - 4),
                dimen = self.item_dimen:copy(),
                shortcut = item_shortcut,
                shortcut_style = shortcut_style,
                entry = item,
                menu = self,
                linesize = self.linesize,
                single_line = self.single_line,
                multilines_forced = self.multilines_forced,
                multilines_show_more_text = multilines_show_more_text,
                items_max_lines = self.items_max_lines,
                truncate_left = self.truncate_left,
                line_color = self.line_color,
                items_padding = self.items_padding,
                handle_hold_on_hold_release = self.handle_hold_on_hold_release,
            }
            table.insert(self.item_group, item_tmp)
            table.insert(self.layout, { item_tmp })
        end

        self:updatePageInfo(select_number)
        self:mergeTitleBarIntoLayout()

        UIManager:setDirty(self.show_parent, function()
            local refresh_dimen =
                old_dimen and old_dimen:combine(self.dimen)
                or self.dimen
            return "ui", refresh_dimen
        end)
    end)

    Font.fontmap.smallinfofont = saved_smallinfo
    if not ok then
        error(err)
    end
end

return ListMenu
