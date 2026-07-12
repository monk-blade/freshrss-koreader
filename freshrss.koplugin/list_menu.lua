-- FreshRSS article list Menu: apply list Latin font without remapping global
-- Font.fontmap.smallinfofont (CoverBrowser/bookshelf use that key on exit).
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")
local ListMenuItem = dofile(plugin_dir .. "/list_menu_item.lua")

local ListMenu = Menu:extend{
    name = "freshrss_article_list",
    list_fonts = nil,
}

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
