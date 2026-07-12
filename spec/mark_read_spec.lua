package.path = "./freshrss.koplugin/?.lua;./?.lua;" .. package.path

-- Mark-read-on-open setting semantics (mirrors Plugin:markReadOnOpen).
local function markReadOnOpen(settings)
    local value = settings and settings.readSetting and settings:readSetting("freshrss_mark_read_on_open")
    if value == nil then return true end
    return value and true or false
end

describe("FreshRSS mark-read-on-open policy", function()
    it("defaults to on when unset", function()
        local settings = { readSetting = function() return nil end }
        assert.is_true(markReadOnOpen(settings))
    end)

    it("honors explicit off", function()
        local store = { freshrss_mark_read_on_open = false }
        local settings = {
            readSetting = function(_, k) return store[k] end,
        }
        assert.is_false(markReadOnOpen(settings))
    end)

    it("honors explicit on", function()
        local store = { freshrss_mark_read_on_open = true }
        local settings = {
            readSetting = function(_, k) return store[k] end,
        }
        assert.is_true(markReadOnOpen(settings))
    end)
end)
