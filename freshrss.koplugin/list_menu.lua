-- FreshRSS article list Menu: apply list Latin font without remapping global
-- Font.fontmap.smallinfofont (CoverBrowser/bookshelf use that key on exit).
local Menu = require("ui/widget/menu")

local ListMenu = Menu:extend{
    name = "freshrss_article_list",
    list_fonts = nil,
}

---Temporarily point smallinfofont at the list Latin face for MenuItem building.
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
    local ok, err = pcall(Menu.updateItems, self, select_number, no_recalculate_dimen)
    Font.fontmap.smallinfofont = saved_smallinfo
    if not ok then
        error(err)
    end
end

return ListMenu
