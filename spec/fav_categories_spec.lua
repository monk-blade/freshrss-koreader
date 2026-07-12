package.path = "./freshrss.koplugin/?.lua;./?.lua;" .. package.path
local FavCategories = dofile("./freshrss.koplugin/fav_categories.lua")

describe("FreshRSS favorite categories", function()
    local store
    local settings

    before_each(function()
        store = {}
        settings = {
            readSetting = function(_, k) return store[k] end,
            saveSetting = function(_, k, v) store[k] = v end,
            flush = function() end,
        }
    end)

    it("builds two-letter tiles from names", function()
        assert.equals("NE", FavCategories.twoLetters("News"))
        assert.equals("TE", FavCategories.twoLetters("Tech"))
        assert.equals("AB", FavCategories.twoLetters("A B"))
    end)

    it("builds two-letter tiles from Gujarati without byte-slicing", function()
        -- "એડિટોરિયલ" — first two Unicode letters, not two UTF-8 bytes
        local tile = FavCategories.twoLetters("એડિટોરિયલ")
        assert.not_equals("??", tile)
        local chars = {}
        for uchar in tile:gmatch("([%z\1-\127\194-\244][\128-\191]*)") do
            table.insert(chars, uchar)
        end
        assert.equals(2, #chars)
        assert.equals("એ", chars[1])
        assert.equals("ડ", chars[2])
    end)

    it("persists add remove and icon", function()
        FavCategories.add(settings, "user/-/label/News")
        assert.is_true(FavCategories.isFavorite(settings, "user/-/label/News"))
        FavCategories.setIcon(settings, "user/-/label/News", "newspaper")
        local list = FavCategories.read(settings)
        assert.equals(1, #list)
        assert.equals("newspaper", list[1].icon)
        FavCategories.remove(settings, "user/-/label/News")
        assert.equals(0, #FavCategories.read(settings))
    end)

    it("caps at MAX favorites", function()
        for i = 1, FavCategories.MAX + 3 do
            FavCategories.add(settings, "user/-/label/C" .. i)
        end
        assert.equals(FavCategories.MAX, #FavCategories.read(settings))
    end)
end)
