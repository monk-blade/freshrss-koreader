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
        attributes = function(path, mode)
            local ok = os.execute(string.format('test -d %q', path))
            if ok == true or ok == 0 then
                if mode == "mode" then return "directory" end
                return { mode = "directory", size = 0 }
            end
            local f = io.open(path, "r")
            if f then
                local size = f:seek("end")
                f:close()
                if mode == "mode" then return "file" end
                return { mode = "file", size = size }
            end
            return nil
        end,
        dir = function(path)
            local names = {}
            local p = io.popen(string.format('ls -A %q 2>/dev/null', path))
            if p then
                for line in p:lines() do
                    table.insert(names, line)
                end
                p:close()
            end
            local i = 0
            return function()
                i = i + 1
                return names[i]
            end
        end,
        currentdir = function()
            local p = io.popen("pwd")
            local cwd = p and p:read("*l") or "."
            if p then p:close() end
            return cwd
        end,
    }
    package.preload["lfs"] = function() return stub end
    package.preload["libs/libkoreader-lfs"] = function() return stub end
end

return helpers
