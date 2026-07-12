-- Local image cache for MuPDF HTML rendering (no remote URL fetches by MuPDF).
-- MuPDF resolves <img src> via html_resource_directory (relative filenames only).
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

local CONTENT_TYPE_EXT = {
    ["image/jpeg"] = "jpg",
    ["image/jpg"] = "jpg",
    ["image/png"] = "png",
    ["image/gif"] = "gif",
    ["image/webp"] = "webp",
    ["image/svg+xml"] = "svg",
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

function Images.extensionFromContentType(content_type)
    local ct = tostring(content_type or ""):lower()
    ct = ct:match("^([^;]+)") or ct
    ct = ct:gsub("^%s+", ""):gsub("%s+$", "")
    return CONTENT_TYPE_EXT[ct]
end

---True if data looks like a real image (rejects HTML error pages saved as .jpg).
---@return boolean ok, string|nil ext
function Images.isValidImageData(data)
    if not data or #data < 3 then return false end
    local b1, b2, b3, b4 = data:byte(1, 4)
    -- JPEG
    if b1 == 0xFF and b2 == 0xD8 then return true, "jpg" end
    -- PNG
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then return true, "png" end
    -- GIF
    if data:sub(1, 3) == "GIF" then return true, "gif" end
    -- WEBP (RIFF....WEBP)
    if data:sub(1, 4) == "RIFF" and #data >= 12 and data:sub(9, 12) == "WEBP" then
        return true, "webp"
    end
    -- SVG / XML+SVG (reject HTML)
    local trimmed = data:match("^%s*(.*)") or data
    local lower = trimmed:lower()
    if lower:find("<!doctype html", 1, true) or lower:find("<html", 1, true) then
        return false
    end
    if (trimmed:sub(1, 1) == "<" or trimmed:sub(1, 5) == "<?xml")
        and lower:find("<svg", 1, true)
    then
        return true, "svg"
    end
    return false
end

function Images.filenameForUrl(url)
    url = Images.normalizeUrl(url)
    return Images.hashUrl(url) .. "." .. Images.extensionForUrl(url)
end

---Decode common HTML entities in image URLs so hash/map keys stay consistent.
function Images.normalizeUrl(url)
    url = tostring(url or "")
    url = url:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&#39;", "'")
    if url:sub(1, 2) == "//" then
        url = "https:" .. url
    end
    return url
end

local function isRemoteHttp(url)
    local u = Images.normalizeUrl(url)
    return u:sub(1, 7) == "http://" or u:sub(1, 8) == "https://"
end

---Collect remote image URL candidates from an <img> tag (src, then data-src).
function Images.urlsFromImgTag(tag)
    local urls = {}
    local seen = {}
    local function add(raw)
        if not raw or raw == "" or raw:sub(1, 5) == "data:" then return end
        local norm = Images.normalizeUrl(raw:gsub("^%s+", ""):gsub("%s+$", ""))
        if isRemoteHttp(norm) and not seen[norm] then
            seen[norm] = true
            table.insert(urls, norm)
        end
    end
    -- Parse attributes by name so "src" inside "data-src" is not matched.
    local src, data_src
    for attr, val in tag:gmatch("([%w:_%-]+)%s*=%s*\"([^\"]+)\"") do
        local lower = attr:lower()
        if lower == "src" then src = val
        elseif lower == "data-src" then data_src = val
        end
    end
    for attr, val in tag:gmatch("([%w:_%-]+)%s*=%s*'([^']+)'") do
        local lower = attr:lower()
        if lower == "src" and not src then src = val
        elseif lower == "data-src" and not data_src then data_src = val
        end
    end
    add(src)
    add(data_src)
    return urls
end

---Resolve cached filename for a URL (handles magic-byte extension corrections).
function Images.findCachedFilename(dir, url)
    local norm = Images.normalizeUrl(url)
    local preferred = Images.filenameForUrl(norm)
    if Images.isCached(dir, preferred) then
        return preferred
    end
    local base = Images.hashUrl(norm)
    for _, ext in ipairs({ "jpg", "png", "gif", "webp", "svg" }) do
        local alt = base .. "." .. ext
        if alt ~= preferred and Images.isCached(dir, alt) then
            return alt
        end
    end
    return nil
end
---Extract http(s) image URLs from HTML (capped).
function Images.extractImageUrls(html)
    local urls = {}
    local seen = {}
    local body = tostring(html or "")
    for tag in body:gmatch("<%s*[iI][mM][gG][^>]*>") do
        for _, src in ipairs(Images.urlsFromImgTag(tag)) do
            if not seen[src] then
                seen[src] = true
                table.insert(urls, src)
                if #urls >= Images.MAX_IMAGES then return urls end
            end
        end
    end
    return urls
end

local function rawSrcAttr(tag)
    for attr, val in tag:gmatch("([%w:_%-]+)%s*=%s*\"([^\"]+)\"") do
        if attr:lower() == "src" then return val end
    end
    for attr, val in tag:gmatch("([%w:_%-]+)%s*=%s*'([^']+)'") do
        if attr:lower() == "src" then return val end
    end
    return nil
end

---Rewrite <img> tags: map[url] = local filename keeps image; missing → [image] placeholder.
---Emits relative filenames only (MuPDF loads them via html_resource_directory).
function Images.rewriteHtml(html, url_to_filename, _opts)
    url_to_filename = url_to_filename or {}
    local body = tostring(html or "")
    return (body:gsub("<%s*[iI][mM][gG][^>]*>", function(tag)
        local candidates = Images.urlsFromImgTag(tag)
        local local_name = nil
        for _, url in ipairs(candidates) do
            local_name = url_to_filename[url]
            if local_name then break end
        end
        if local_name then
            return string.format('<img src="%s"/>', local_name)
        end
        -- Remote src/data-src present but not cached → placeholder
        if #candidates > 0 then
            return " <span>[image]</span> "
        end

        local src = rawSrcAttr(tag)
        if not src or src == "" or src:sub(1, 5) == "data:" then
            return " <span>[image]</span> "
        end
        local normalized = Images.normalizeUrl(src)
        local_name = url_to_filename[normalized] or url_to_filename[src]
        if local_name then
            return string.format('<img src="%s"/>', local_name)
        end
        -- Keep local relative filenames and file:// (safety); strip remote.
        if normalized:match("^file:") then
            return string.format('<img src="%s"/>', normalized:gsub('"', ""))
        end
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
    if not (attrs and attrs.mode == "file" and (attrs.size or 0) > 0) then
        return false
    end
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(512) or ""
    f:close()
    if not Images.isValidImageData(head) then
        os.remove(path)
        return false
    end
    return true
end

local function finalizeDownloadedFile(tmp, path, preferred_filename, dir, headers)
    local f = io.open(tmp, "rb")
    if not f then
        os.remove(tmp)
        return false
    end
    local head = f:read(512) or ""
    f:close()
    local valid, sniffed = Images.isValidImageData(head)
    if not valid then
        os.remove(tmp)
        return false
    end

    local final_name = preferred_filename
    local ext = sniffed
    if not ext and headers then
        local ct = headers["content-type"] or headers["Content-Type"]
        ext = Images.extensionFromContentType(ct)
    end
    if ext then
        local base = preferred_filename:match("^(.*)%.[^%.]+$") or preferred_filename
        local want = base .. "." .. ext
        if want ~= preferred_filename then
            final_name = want
        end
    end

    local dest = dir .. "/" .. final_name
    os.remove(dest)
    if os.rename(tmp, dest) then
        return true, final_name
    end
    local src = io.open(tmp, "rb")
    local dst = src and io.open(dest, "wb")
    if src and dst then
        dst:write(src:read("*a") or "")
        src:close()
        dst:close()
        os.remove(tmp)
        return true, final_name
    end
    if src then src:close() end
    os.remove(tmp)
    return false
end

---Download one URL into dir/filename. Returns true, final_filename on success.
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
    local ok, code, headers = http.request{
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
    return finalizeDownloadedFile(tmp, path, filename, dir, headers)
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
        local norm = Images.normalizeUrl(url)
        local cached = Images.findCachedFilename(dir, norm)
        if cached then
            map[norm] = cached
        elseif want_download then
            local filename = Images.filenameForUrl(norm)
            local ok, saved = Images.downloadOne(norm, dir, filename)
            if ok then
                map[norm] = saved or filename
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
        local norm = Images.normalizeUrl(url)
        local filename = Images.findCachedFilename(dir, norm)
        if filename then
            map[norm] = filename
        end
    end
    return map, dir
end
return Images
