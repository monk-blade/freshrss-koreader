-- Local image cache for MuPDF HTML rendering (no remote URL fetches by MuPDF).
local Images = {}

Images.MAX_IMAGES = 10
Images.MAX_BYTES = 1024 * 1024
Images.CONNECT_TIMEOUT = 5
Images.TOTAL_TIMEOUT = 12

local VALID_EXT = {
    jpg = true,
    jpeg = true,
    png = true,
    gif = true,
    webp = true,
    svg = true,
}

local function bxor(a, b)
    local bit = rawget(_G, "bit") or rawget(_G, "bit32")
    if bit and bit.bxor then
        return bit.bxor(a, b)
    end
    -- Portable fallback
    local r, p = 0, 1
    while a > 0 or b > 0 do
        local abit, bbit = a % 2, b % 2
        if abit ~= bbit then r = r + p end
        a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
    end
    return r
end

-- FNV-1a 32-bit — pure Lua so unit tests need no FFI crypto.
function Images.hashUrl(url)
    local hash = 2166136261
    local s = tostring(url or "")
    for i = 1, #s do
        hash = bxor(hash, s:byte(i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

function Images.extensionForUrl(url)
    local clean = tostring(url or "")
    clean = clean:match("^(.-)%?") or clean
    clean = clean:match("^(.-)#") or clean
    local ext = clean:match("%.([A-Za-z0-9]+)$")
    if not ext then return "jpg" end
    ext = ext:lower()
    if ext == "jpeg" then ext = "jpg" end
    return VALID_EXT[ext] and ext or "jpg"
end

function Images.filenameForUrl(url)
    return Images.hashUrl(url) .. "." .. Images.extensionForUrl(url)
end

---Extract http(s) image URLs from HTML (capped).
function Images.extractImageUrls(html)
    local urls = {}
    local seen = {}
    local body = tostring(html or "")
    for tag in body:gmatch("<%s*[iI][mM][gG][^>]*>") do
        local src = tag:match("[sS][rR][cC]%s*=%s*\"([^\"]+)\"")
            or tag:match("[sS][rR][cC]%s*=%s*'([^']+)'")
            or tag:match("[sS][rR][cC]%s*=%s*([^%s>]+)")
        if src then
            src = src:gsub("^%s+", ""):gsub("%s+$", "")
            if src:sub(1, 2) == "//" then
                src = "https:" .. src
            end
            if (src:sub(1, 7) == "http://" or src:sub(1, 8) == "https://")
                and not seen[src]
            then
                seen[src] = true
                table.insert(urls, src)
                if #urls >= Images.MAX_IMAGES then break end
            end
        end
    end
    return urls
end

---Rewrite <img> tags: map[url] = local filename keeps image; missing → [image] placeholder.
function Images.rewriteHtml(html, url_to_filename)
    url_to_filename = url_to_filename or {}
    local body = tostring(html or "")
    return (body:gsub("<%s*[iI][mM][gG][^>]*>", function(tag)
        local src = tag:match("[sS][rR][cC]%s*=%s*\"([^\"]+)\"")
            or tag:match("[sS][rR][cC]%s*=%s*'([^']+)'")
            or tag:match("[sS][rR][cC]%s*=%s*([^%s>]+)")
        if not src or src == "" or src:sub(1, 5) == "data:" then
            return " <span>[image]</span> "
        end
        local normalized = src
        if normalized:sub(1, 2) == "//" then
            normalized = "https:" .. normalized
        end
        local local_name = url_to_filename[normalized] or url_to_filename[src]
        if local_name then
            return string.format('<img src="%s"/>', local_name)
        end
        -- Already a local filename (no scheme)
        if not normalized:match("^https?://") and not normalized:match("^//") then
            return string.format('<img src="%s"/>', normalized:gsub('"', ""))
        end
        return " <span>[image]</span> "
    end))
end

function Images.directory(data_dir)
    local base = data_dir or ""
    if base == "" then
        local ok, DataStorage = pcall(require, "datastorage")
        if ok and DataStorage and DataStorage.getDataDir then
            base = DataStorage:getDataDir() .. "/freshrss"
        else
            base = "freshrss"
        end
    end
    return base:gsub("/+$", "") .. "/images"
end

function Images.ensureDirectory(dir)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then
        local parent = dir:match("^(.*)/[^/]+$")
        if parent and lfs.attributes(parent, "mode") ~= "directory" then
            lfs.mkdir(parent)
        end
        lfs.mkdir(dir)
    end
    return dir
end

function Images.isCached(dir, filename)
    local path = dir .. "/" .. filename
    local lfs = require("libs/libkoreader-lfs")
    local attrs = lfs.attributes(path)
    return attrs and attrs.mode == "file" and (attrs.size or 0) > 0
end

---Download one URL into dir/filename. Returns true on success.
function Images.downloadOne(url, dir, filename)
    local http = require("socket.http")
    local socketutil = require("socketutil")
    local path = dir .. "/" .. filename
    local tmp = path .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then return false end

    local bytes = 0
    local capped = false
    local sink = function(chunk)
        if not chunk then
            if file then file:close(); file = nil end
            return 1
        end
        bytes = bytes + #chunk
        if bytes > Images.MAX_BYTES then
            capped = true
            if file then file:close(); file = nil end
            return nil, "too large"
        end
        return file:write(chunk)
    end

    socketutil:set_timeout(Images.CONNECT_TIMEOUT, Images.TOTAL_TIMEOUT)
    local ok, code = http.request{
        url = url,
        method = "GET",
        sink = sink,
        redirect = true,
    }
    socketutil:reset_timeout()
    if file then file:close() end

    if capped or not ok or tonumber(code or 0) ~= 200 then
        os.remove(tmp)
        return false
    end
    os.remove(path)
    if os.rename(tmp, path) then
        return true
    end
    local src = io.open(tmp, "rb")
    local dst = src and io.open(path, "wb")
    if src and dst then
        dst:write(src:read("*a") or "")
        src:close()
        dst:close()
        os.remove(tmp)
        return true
    end
    if src then src:close() end
    os.remove(tmp)
    return false
end

---Build url→filename map; download missing when requested and online.
---@return table url_to_filename, string resource_dir, number downloaded, number missing
function Images.prepare(html, opts)
    opts = opts or {}
    local dir = Images.ensureDirectory(Images.directory(opts.data_dir))
    local urls = Images.extractImageUrls(html)
    local map = {}
    local downloaded = 0
    local missing = 0
    local want_download = opts.download ~= false and opts.is_online ~= false

    for _, url in ipairs(urls) do
        local filename = Images.filenameForUrl(url)
        if Images.isCached(dir, filename) then
            map[url] = filename
        elseif want_download then
            if Images.downloadOne(url, dir, filename) then
                map[url] = filename
                downloaded = downloaded + 1
            else
                missing = missing + 1
            end
        else
            missing = missing + 1
        end
    end
    return map, dir, downloaded, missing
end

---Cached-only map (no network) for fast first paint.
function Images.cachedMap(html, data_dir)
    local dir = Images.directory(data_dir)
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    local map = {}
    if not lfs_ok then return map, dir end
    if lfs.attributes(dir, "mode") ~= "directory" then
        return map, dir
    end
    for _, url in ipairs(Images.extractImageUrls(html)) do
        local filename = Images.filenameForUrl(url)
        if Images.isCached(dir, filename) then
            map[url] = filename
        end
    end
    return map, dir
end

return Images
