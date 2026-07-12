-- Test doubles for KOReader modules (json / lfs) so specs run without kodev.
local helpers = {}

local function serialize(value, seen)
    local t = type(value)
    if t == "nil" then
        return "nil"
    elseif t == "boolean" or t == "number" then
        return tostring(value)
    elseif t == "string" then
        return string.format("%q", value)
    elseif t == "table" then
        if seen[value] then error("circular table") end
        seen[value] = true
        local parts = {}
        local keys = {}
        for key in pairs(value) do table.insert(keys, key) end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, key in ipairs(keys) do
            table.insert(parts, "[" .. serialize(key, seen) .. "]=" .. serialize(value[key], seen))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("unsupported type " .. t)
end

function helpers.encode(value)
    return "return " .. serialize(value, {})
end

function helpers.decode(text)
    local chunk, err = load(text)
    if not chunk then error(err or "decode failed") end
    return chunk()
end

function helpers.install_json()
    package.preload["json"] = function()
        return {
            encode = helpers.encode,
            decode = helpers.decode,
        }
    end
end

function helpers.install_lfs()
    local stub = {
        mkdir = function(path)
            os.execute(string.format('mkdir -p %q', path))
            return true
        end,
    }
    package.preload["lfs"] = function() return stub end
    package.preload["libs/libkoreader-lfs"] = function() return stub end
end

return helpers
