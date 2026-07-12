-- Local image cache for MuPDF HTML rendering (no remote URL fetches by MuPDF).
-- MuPDF resolves <img src> via html_resource_directory (relative filenames only).
local Images = {}

Images.MAX_IMAGES = 10
Images.MAX_BYTES = 1024 * 1024
Images.MAX_PARALLEL = 3
Images.CONNECT_TIMEOUT = 5
Images.TOTAL_TIMEOUT = 12
Images.SELECT_TIMEOUT = 0.2
Images.MAX_REDIRECTS = 5

-- Settings cycles (defaults match the constants above).
Images.SETTING_MAX_IMAGES = "freshrss_image_max_per_article"
Images.SETTING_SYNC_BUDGET = "freshrss_image_sync_budget"
Images.SETTING_PARALLEL = "freshrss_image_parallel"
Images.SETTING_MAX_BYTES = "freshrss_image_max_bytes"
Images.SETTING_TIMEOUT_PROFILE = "freshrss_image_timeout_profile"
Images.MAX_IMAGES_CAPS = { 5, 10, 15, 20 }
Images.SYNC_BUDGET_CAPS = { 20, 50, 100, 150 }
Images.PARALLEL_CAPS = { 1, 2, 3 }
Images.MAX_BYTES_CAPS = { 512 * 1024, 1024 * 1024, 2 * 1024 * 1024 }
Images.TIMEOUT_PROFILES = {
    short = { connect = 3, total = 8, label = "short" },
    default = { connect = 5, total = 12, label = "default" },
    long = { connect = 10, total = 25, label = "long" },
}
Images.TIMEOUT_PROFILE_ORDER = { "short", "default", "long" }
Images.DEFAULT_SYNC_BUDGET = 50

local function cycleCap(current, caps, default)
    current = tonumber(current) or default
    for i, cap in ipairs(caps) do
        if cap == current and caps[i + 1] then
            return caps[i + 1]
        elseif cap == current then
            return caps[1]
        elseif current < cap then
            return cap
        end
    end
    return caps[1] or default
end

local function clampToCaps(value, caps, default)
    value = tonumber(value) or default
    for _, cap in ipairs(caps) do
        if cap == value then return value end
    end
    -- Snap to nearest listed cap
    local best, best_dist = default, math.huge
    for _, cap in ipairs(caps) do
        local d = math.abs(cap - value)
        if d < best_dist then
            best, best_dist = cap, d
        end
    end
    return best
end

function Images.readMaxImages()
    local raw = G_reader_settings and G_reader_settings:readSetting(Images.SETTING_MAX_IMAGES)
    return clampToCaps(raw, Images.MAX_IMAGES_CAPS, Images.MAX_IMAGES)
end

function Images.cycleMaxImages()
    local next_cap = cycleCap(Images.readMaxImages(), Images.MAX_IMAGES_CAPS, Images.MAX_IMAGES)
    G_reader_settings:saveSetting(Images.SETTING_MAX_IMAGES, next_cap)
    G_reader_settings:flush()
    return next_cap
end

function Images.readSyncBudget()
    local raw = G_reader_settings and G_reader_settings:readSetting(Images.SETTING_SYNC_BUDGET)
    return clampToCaps(raw, Images.SYNC_BUDGET_CAPS, Images.DEFAULT_SYNC_BUDGET)
end

function Images.cycleSyncBudget()
    local next_cap = cycleCap(Images.readSyncBudget(), Images.SYNC_BUDGET_CAPS, Images.DEFAULT_SYNC_BUDGET)
    G_reader_settings:saveSetting(Images.SETTING_SYNC_BUDGET, next_cap)
    G_reader_settings:flush()
    return next_cap
end

function Images.readMaxParallel()
    local raw = G_reader_settings and G_reader_settings:readSetting(Images.SETTING_PARALLEL)
    return clampToCaps(raw, Images.PARALLEL_CAPS, Images.MAX_PARALLEL)
end

function Images.cycleMaxParallel()
    local next_cap = cycleCap(Images.readMaxParallel(), Images.PARALLEL_CAPS, Images.MAX_PARALLEL)
    G_reader_settings:saveSetting(Images.SETTING_PARALLEL, next_cap)
    G_reader_settings:flush()
    return next_cap
end

function Images.readMaxBytes()
    local raw = G_reader_settings and G_reader_settings:readSetting(Images.SETTING_MAX_BYTES)
    return clampToCaps(raw, Images.MAX_BYTES_CAPS, Images.MAX_BYTES)
end

function Images.cycleMaxBytes()
    local next_cap = cycleCap(Images.readMaxBytes(), Images.MAX_BYTES_CAPS, Images.MAX_BYTES)
    G_reader_settings:saveSetting(Images.SETTING_MAX_BYTES, next_cap)
    G_reader_settings:flush()
    return next_cap
end

function Images.formatMaxBytesLabel(bytes)
    bytes = tonumber(bytes) or Images.MAX_BYTES
    if bytes < 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    end
    if bytes % (1024 * 1024) == 0 then
        return string.format("%d MB", bytes / (1024 * 1024))
    end
    return string.format("%.1f MB", bytes / (1024 * 1024))
end

function Images.readTimeoutProfile()
    local key = G_reader_settings and G_reader_settings:readSetting(Images.SETTING_TIMEOUT_PROFILE)
    if type(key) == "string" and Images.TIMEOUT_PROFILES[key] then
        return key
    end
    return "default"
end

function Images.readTimeouts()
    local profile = Images.TIMEOUT_PROFILES[Images.readTimeoutProfile()] or Images.TIMEOUT_PROFILES.default
    return profile.connect, profile.total
end

function Images.cycleTimeoutProfile()
    local current = Images.readTimeoutProfile()
    local next_key = Images.TIMEOUT_PROFILE_ORDER[1]
    for i, key in ipairs(Images.TIMEOUT_PROFILE_ORDER) do
        if key == current then
            next_key = Images.TIMEOUT_PROFILE_ORDER[i + 1] or Images.TIMEOUT_PROFILE_ORDER[1]
            break
        end
    end
    G_reader_settings:saveSetting(Images.SETTING_TIMEOUT_PROFILE, next_key)
    G_reader_settings:flush()
    return next_key
end

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
-- @param max_images number|nil override cap (defaults to Images.readMaxImages())
function Images.extractImageUrls(html, max_images)
    local urls = {}
    local seen = {}
    local body = tostring(html or "")
    local cap = tonumber(max_images) or Images.readMaxImages()
    for tag in body:gmatch("<%s*[iI][mM][gG][^>]*>") do
        for _, src in ipairs(Images.urlsFromImgTag(tag)) do
            if not seen[src] then
                seen[src] = true
                table.insert(urls, src)
                if #urls >= cap then return urls end
            end
        end
    end
    return urls
end

---Count total remote images and how many are cached locally.
function Images.countImageStats(html, data_dir)
    local urls = Images.extractImageUrls(html)
    local total = #urls
    if total == 0 then return { total = 0, cached = 0 } end
    local dir = Images.directory(data_dir)
    local cached = 0
    for _, url in ipairs(urls) do
        local norm = Images.normalizeUrl(url)
        if Images.findCachedFilename(dir, norm) then
            cached = cached + 1
        end
    end
    return { total = total, cached = cached }
end

---Placeholder span text for a missing/remote image.
function Images.placeholderText(opts)
    opts = opts or {}
    if opts.show_images == false then
        return "[image hidden]"
    end
    return "[image · tap to fetch]"
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
function Images.rewriteHtml(html, url_to_filename, opts)
    url_to_filename = url_to_filename or {}
    opts = opts or {}
    local placeholder = Images.placeholderText(opts)
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
            return string.format(' <span>%s</span> ', placeholder)
        end

        local src = rawSrcAttr(tag)
        if not src or src == "" or src:sub(1, 5) == "data:" then
            return string.format(' <span>%s</span> ', placeholder)
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
        return string.format(' <span>%s</span> ', placeholder)
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

---Resolve image dir to an absolute path for MuPDF html_resource_directory.
function Images.absoluteDirectory(dir)
    dir = tostring(dir or "")
    if dir == "" then return dir end
    if dir:sub(1, 1) == "/" then return dir end
    local lfs = require("libs/libkoreader-lfs")
    local cwd = lfs.currentdir and lfs.currentdir() or nil
    if not cwd or cwd == "" then return dir end
    if dir == "." then return cwd end
    if dir:sub(1, 2) == "./" then
        return cwd:gsub("/+$", "") .. "/" .. dir:sub(3)
    end
    return cwd:gsub("/+$", "") .. "/" .. dir
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
    return Images.absoluteDirectory(dir)
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
        if bytes > Images.readMaxBytes() then
            capped = true
            if file then file:close(); file = nil end
            return nil, "too large"
        end
        return file:write(chunk)
    end

    local connect_t, total_t = Images.readTimeouts()
    socketutil:set_timeout(connect_t, total_t)
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

local pumpBodyData

local function closeJobSocket(job)
    if job.sock then
        pcall(function() job.sock:close() end)
        job.sock = nil
    end
end

local function failJob(job)
    if job.file then
        pcall(function() job.file:close() end)
        job.file = nil
    end
    if job.tmp then
        os.remove(job.tmp)
        job.tmp = nil
    end
    closeJobSocket(job)
    job.ok = false
    job.saved = nil
    job.state = "done"
    job.want_read = false
    job.want_write = false
end

local function succeedJob(job, headers)
    if job.file then
        pcall(function() job.file:close() end)
        job.file = nil
    end
    closeJobSocket(job)
    local path = job.dir .. "/" .. job.filename
    local ok, saved = finalizeDownloadedFile(job.tmp, path, job.filename, job.dir, headers)
    job.tmp = nil
    job.ok = ok and true or false
    job.saved = ok and (saved or job.filename) or nil
    if not ok then
        job.ok = false
        job.saved = nil
    end
    job.state = "done"
    job.want_read = false
    job.want_write = false
end

local function jobTimedOut(job)
    local _, total_t = Images.readTimeouts()
    return (os.time() - (job.started_at or os.time())) > total_t
end

---LuaSocket uses "timeout"; LuaSec non-blocking SSL uses wantread/wantwrite.
local function isWouldBlock(err)
    return err == "timeout" or err == "wantread" or err == "wantwrite"
end

local function applyWouldBlock(job, err)
    if err == "wantread" then
        job.want_read = true
        job.want_write = false
    elseif err == "wantwrite" then
        job.want_read = false
        job.want_write = true
    end
    -- "timeout" keeps existing want_read/want_write interest.
end

local function parseRequestUrl(raw_url)
    local url_mod = require("socket.url")
    local parsed = url_mod.parse(Images.normalizeUrl(raw_url))
    if not parsed or not parsed.host then return nil end
    local scheme = (parsed.scheme or "http"):lower()
    if scheme ~= "http" and scheme ~= "https" then return nil end
    local path = parsed.path or "/"
    if parsed.query and parsed.query ~= "" then
        path = path .. "?" .. parsed.query
    end
    local port = tonumber(parsed.port)
    if not port then
        port = scheme == "https" and 443 or 80
    end
    return {
        host = parsed.host,
        port = port,
        path = path,
        https = scheme == "https",
        authority = parsed.authority or parsed.host,
    }
end

local function beginJobConnect(job)
    local parsed = parseRequestUrl(job.url)
    if not parsed then
        failJob(job)
        return
    end
    job.host = parsed.host
    job.port = parsed.port
    job.path = parsed.path
    job.https = parsed.https
    job.authority = parsed.authority or parsed.host
    job.send_buf = string.format(
        "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: FreshRSS-KOReader\r\nAccept: image/*,*/*;q=0.8\r\nConnection: close\r\n\r\n",
        parsed.path,
        job.authority
    )
    job.hdr_buf = ""
    job.body_buf = ""
    job.bytes = 0
    job.headers = {}
    job.status_code = nil
    job.body_mode = nil
    job.chunk_state = nil
    job.chunk_remain = 0
    job.content_length = nil

    local socket = require("socket")
    local sock = socket.tcp()
    if not sock then
        failJob(job)
        return
    end
    sock:settimeout(0)
    job.sock = sock
    job.state = "connect"
    job.want_read = false
    job.want_write = true
    local ok, err = sock:connect(job.host, job.port)
    if ok then
        if job.https then
            job.state = "ssl"
            job.want_read = true
            job.want_write = true
        else
            job.state = "send"
            job.want_read = false
            job.want_write = true
        end
    elseif err ~= "timeout" then
        failJob(job)
    end
end

local function startSslHandshake(job)
    local ok_ssl, ssl = pcall(require, "ssl")
    if not ok_ssl or not ssl or not ssl.wrap then
        failJob(job)
        return
    end
    local wrapped, err = ssl.wrap(job.sock, {
        mode = "client",
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
        verify = "none",
    })
    if not wrapped then
        failJob(job)
        return
    end
    pcall(function() wrapped:sni(job.host) end)
    wrapped:settimeout(0)
    job.sock = wrapped
    job.state = "ssl"
    job.want_read = true
    job.want_write = true
end

local function pumpSsl(job)
    if type(job.sock.dohandshake) ~= "function" then
        startSslHandshake(job)
        if job.state == "done" then return end
    end
    local ok, err = job.sock:dohandshake()
    if ok then
        job.state = "send"
        job.want_read = false
        job.want_write = true
    elseif err == "wantread" then
        job.want_read = true
        job.want_write = false
    elseif err == "wantwrite" then
        job.want_read = false
        job.want_write = true
    else
        failJob(job)
    end
end

local function appendBody(job, data)
    if not data or data == "" then return true end
    job.bytes = job.bytes + #data
    if job.bytes > Images.readMaxBytes() then
        failJob(job)
        return false
    end
    if not job.file:write(data) then
        failJob(job)
        return false
    end
    return true
end

local function openBodyFile(job)
    local path = job.dir .. "/" .. job.filename
    job.tmp = path .. ".tmp"
    job.file = io.open(job.tmp, "wb")
    if not job.file then
        failJob(job)
        return false
    end
    return true
end

local function handleRedirect(job)
    local location = job.headers["location"]
    if not location or location == "" then
        failJob(job)
        return
    end
    job.redirects = (job.redirects or 0) + 1
    if job.redirects > Images.MAX_REDIRECTS then
        failJob(job)
        return
    end
    if location:sub(1, 1) == "/" then
        local scheme = job.https and "https" or "http"
        location = string.format("%s://%s%s", scheme, job.authority or job.host, location)
    elseif not location:match("^https?://") then
        failJob(job)
        return
    end
    if job.file then
        pcall(function() job.file:close() end)
        job.file = nil
    end
    if job.tmp then
        os.remove(job.tmp)
        job.tmp = nil
    end
    closeJobSocket(job)
    job.url = Images.normalizeUrl(location)
    beginJobConnect(job)
end

local function finishHeaders(job)
    local code = tonumber(job.status_code or 0) or 0
    if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
        handleRedirect(job)
        return
    end
    if code ~= 200 then
        failJob(job)
        return
    end
    if not openBodyFile(job) then return end

    local te = tostring(job.headers["transfer-encoding"] or ""):lower()
    local cl = tonumber(job.headers["content-length"] or "")
    if te:find("chunked", 1, true) then
        job.body_mode = "chunked"
        job.chunk_state = "size"
        job.chunk_remain = 0
    elseif cl then
        job.body_mode = "length"
        job.content_length = cl
        if cl == 0 then
            succeedJob(job, job.headers)
            return
        end
    else
        job.body_mode = "close"
    end
    job.state = "body"
    job.want_read = true
    job.want_write = false
    if job.body_buf ~= "" then
        local leftover = job.body_buf
        job.body_buf = ""
        pumpBodyData(job, leftover)
    end
end

local function parseHeaderBlock(job)
    local block = job.hdr_buf
    local status_line, rest = block:match("^(.-)\r\n(.*)$")
    if not status_line then
        failJob(job)
        return
    end
    local code = status_line:match("^HTTP/%d%.%d%s+(%d+)")
    job.status_code = tonumber(code or 0) or 0
    job.headers = {}
    for line in (rest or ""):gmatch("([^\r\n]+)") do
        local name, value = line:match("^([^:]+):%s*(.*)$")
        if name then
            job.headers[name:lower()] = value
        end
    end
    finishHeaders(job)
end

pumpBodyData = function(job, data)
    if job.state == "done" then return end
    if job.body_mode == "length" then
        local need = job.content_length - job.bytes
        if #data > need then data = data:sub(1, need) end
        if not appendBody(job, data) then return end
        if job.bytes >= job.content_length then
            succeedJob(job, job.headers)
        end
        return
    end
    if job.body_mode == "close" then
        appendBody(job, data)
        return
    end
    -- chunked
    job.body_buf = (job.body_buf or "") .. (data or "")
    while job.state ~= "done" do
        if job.chunk_state == "size" then
            local line, rest = job.body_buf:match("^(.-)\r\n(.*)$")
            if not line then return end
            job.body_buf = rest or ""
            local size = tonumber((line:match("^(%x+)") or ""), 16)
            if not size then
                failJob(job)
                return
            end
            if size == 0 then
                succeedJob(job, job.headers)
                return
            end
            job.chunk_remain = size
            job.chunk_state = "data"
        elseif job.chunk_state == "data" then
            if #job.body_buf < job.chunk_remain then return end
            local chunk = job.body_buf:sub(1, job.chunk_remain)
            job.body_buf = job.body_buf:sub(job.chunk_remain + 1)
            if not appendBody(job, chunk) then return end
            job.chunk_state = "crlf"
        elseif job.chunk_state == "crlf" then
            if #job.body_buf < 2 then return end
            if job.body_buf:sub(1, 2) ~= "\r\n" then
                failJob(job)
                return
            end
            job.body_buf = job.body_buf:sub(3)
            job.chunk_state = "size"
        else
            failJob(job)
            return
        end
    end
end

local function pumpSend(job)
    if job.send_buf == "" then
        job.state = "headers"
        job.want_read = true
        job.want_write = false
        return
    end
    local sent, err, partial = job.sock:send(job.send_buf)
    if sent then
        job.send_buf = job.send_buf:sub(sent + 1)
        if job.send_buf == "" then
            job.state = "headers"
            job.want_read = true
            job.want_write = false
        else
            job.want_read = false
            job.want_write = true
        end
    elseif isWouldBlock(err) then
        if type(partial) == "number" and partial > 0 then
            job.send_buf = job.send_buf:sub(partial + 1)
        end
        applyWouldBlock(job, err)
        if err == "timeout" then
            job.want_read = false
            job.want_write = true
        end
    else
        failJob(job)
    end
end

local function pumpHeaders(job)
    local chunk, err, partial = job.sock:receive(8192)
    local data = chunk or partial
    if data and #data > 0 then
        job.hdr_buf = job.hdr_buf .. data
        local s, e = job.hdr_buf:find("\r\n\r\n", 1, true)
        if s then
            job.body_buf = job.hdr_buf:sub(e + 1)
            job.hdr_buf = job.hdr_buf:sub(1, s - 1)
            parseHeaderBlock(job)
        else
            job.want_read = true
            job.want_write = false
        end
        return
    end
    if err == "closed" then
        failJob(job)
    elseif isWouldBlock(err) then
        applyWouldBlock(job, err)
        if err == "timeout" then
            job.want_read = true
            job.want_write = false
        end
    else
        failJob(job)
    end
end

local function pumpBody(job)
    local chunk, err, partial = job.sock:receive(8192)
    local data = chunk or partial
    if data and #data > 0 then
        pumpBodyData(job, data)
        if job.state == "body" then
            job.want_read = true
            job.want_write = false
        end
        return
    end
    if err == "closed" then
        if job.body_mode == "close" and job.bytes > 0 then
            succeedJob(job, job.headers)
        elseif job.body_mode == "length" and job.bytes >= (job.content_length or 0) then
            succeedJob(job, job.headers)
        else
            failJob(job)
        end
    elseif isWouldBlock(err) then
        applyWouldBlock(job, err)
        if err == "timeout" then
            job.want_read = true
            job.want_write = false
        end
    else
        failJob(job)
    end
end

local function pumpConnect(job)
    local ok, err = job.sock:connect(job.host, job.port)
    if ok or err == "already connected" then
        if job.https then
            startSslHandshake(job)
            if job.state == "ssl" then
                pumpSsl(job)
            end
        else
            job.state = "send"
            job.want_read = false
            job.want_write = true
        end
    elseif err ~= "timeout" then
        -- Some stacks report nil after select once connected.
        local peer = job.sock:getpeername()
        if peer then
            if job.https then
                startSslHandshake(job)
                if job.state == "ssl" then
                    pumpSsl(job)
                end
            else
                job.state = "send"
                job.want_read = false
                job.want_write = true
            end
        else
            failJob(job)
        end
    end
end

local function pumpJob(job)
    if job.state == "done" or jobTimedOut(job) then
        if job.state ~= "done" then failJob(job) end
        return
    end
    if job.state == "connect" then
        pumpConnect(job)
    elseif job.state == "ssl" then
        pumpSsl(job)
    elseif job.state == "send" then
        pumpSend(job)
    elseif job.state == "headers" then
        pumpHeaders(job)
    elseif job.state == "body" then
        pumpBody(job)
    end
end

local function downloadManySerial(jobs, opts)
    local results = {}
    local downloaded = 0
    local max_success = opts.max_success
    local should_cancel = opts.should_cancel
    for i, job in ipairs(jobs) do
        if should_cancel and should_cancel() then break end
        if max_success and downloaded >= max_success then
            results[i] = { ok = false, url = job.url, filename = job.filename }
        else
            local ok, saved = Images.downloadOne(job.url, job.dir, job.filename)
            results[i] = {
                ok = ok and true or false,
                url = job.url,
                filename = ok and (saved or job.filename) or job.filename,
            }
            if ok then downloaded = downloaded + 1 end
        end
        if opts.on_progress then
            opts.on_progress(i, #jobs, results[i])
        end
    end
    return results, downloaded
end

---Try non-blocking socket.select pool; returns nil if LuaSocket unavailable.
local function downloadManyParallel(jobs, opts)
    local ok_socket, socket = pcall(require, "socket")
    if not ok_socket or not socket or not socket.select then
        return nil
    end
    local max_parallel = math.max(1, tonumber(opts.max_parallel) or Images.MAX_PARALLEL)
    local max_success = opts.max_success
    local should_cancel = opts.should_cancel
    local results = {}
    local downloaded = 0
    local next_index = 1
    local active = {}
    local completed = 0
    local total = #jobs

    local function launch(index)
        local src = jobs[index]
        local job = {
            index = index,
            url = src.url,
            dir = src.dir,
            filename = src.filename,
            redirects = 0,
            started_at = os.time(),
            state = "connect",
        }
        beginJobConnect(job)
        if job.state == "done" then
            results[index] = { ok = false, url = src.url, filename = src.filename }
            completed = completed + 1
            if opts.on_progress then
                opts.on_progress(completed, total, results[index])
            end
            return nil
        end
        return job
    end

    local function finishActive(job)
        results[job.index] = {
            ok = job.ok and true or false,
            url = jobs[job.index].url,
            filename = job.ok and (job.saved or jobs[job.index].filename) or jobs[job.index].filename,
        }
        if job.ok then downloaded = downloaded + 1 end
        completed = completed + 1
        if opts.on_progress then
            opts.on_progress(completed, total, results[job.index])
        end
    end

    while completed < total do
        if should_cancel and should_cancel() then break end
        while #active < max_parallel and next_index <= total do
            if max_success and downloaded >= max_success then
                for i = next_index, total do
                    if not results[i] then
                        results[i] = { ok = false, url = jobs[i].url, filename = jobs[i].filename }
                        completed = completed + 1
                        if opts.on_progress then
                            opts.on_progress(completed, total, results[i])
                        end
                    end
                end
                next_index = total + 1
                break
            end
            local job = launch(next_index)
            next_index = next_index + 1
            if job then
                active[#active + 1] = job
            end
        end

        if #active == 0 then
            if next_index > total then break end
        else
            local recvt, sendt = {}, {}
            for _, job in ipairs(active) do
                if job.sock then
                    if job.want_read then recvt[#recvt + 1] = job.sock end
                    if job.want_write then sendt[#sendt + 1] = job.sock end
                end
            end
            if #recvt > 0 or #sendt > 0 then
                socket.select(recvt, sendt, Images.SELECT_TIMEOUT)
            else
                socket.sleep(Images.SELECT_TIMEOUT)
            end

            local still = {}
            for _, job in ipairs(active) do
                pumpJob(job)
                if job.state == "done" then
                    finishActive(job)
                else
                    still[#still + 1] = job
                end
            end
            active = still
        end
    end

    return results, downloaded
end

---Download many images with bounded concurrency (socket.select pool).
---Each job: { url=, dir=, filename= }.
---Falls back to serial downloadOne when LuaSocket is unavailable, opts.serial,
---or the parallel path errors / yields no successes. Failed jobs after a partial
---parallel run are retried serially so transient SSL/select issues don't stick.
---@return table results, number downloaded
function Images.downloadMany(jobs, opts)
    opts = opts or {}
    jobs = jobs or {}
    if #jobs == 0 then return {}, 0 end

    local max_parallel = tonumber(opts.max_parallel) or Images.MAX_PARALLEL
    if opts.serial or max_parallel <= 1 then
        return downloadManySerial(jobs, opts)
    end

    local results, downloaded
    local ok = pcall(function()
        results, downloaded = downloadManyParallel(jobs, opts)
    end)
    if not ok or results == nil then
        return downloadManySerial(jobs, opts)
    end
    downloaded = downloaded or 0
    if downloaded == 0 then
        return downloadManySerial(jobs, opts)
    end

    local retry_jobs, retry_indices = {}, {}
    for i, result in ipairs(results) do
        if not (result and result.ok) then
            retry_jobs[#retry_jobs + 1] = jobs[i]
            retry_indices[#retry_indices + 1] = i
        end
    end
    if #retry_jobs > 0 then
        local retry_opts = {
            max_success = opts.max_success and math.max(0, opts.max_success - downloaded) or nil,
        }
        if not retry_opts.max_success or retry_opts.max_success > 0 then
            local retry_results = downloadManySerial(retry_jobs, retry_opts)
            for j, retry_result in ipairs(retry_results) do
                local idx = retry_indices[j]
                results[idx] = retry_result
                if retry_result and retry_result.ok then
                    downloaded = downloaded + 1
                end
            end
        end
    end
    return results, downloaded
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
    local jobs = {}
    local job_urls = {}

    for _, url in ipairs(urls) do
        local norm = Images.normalizeUrl(url)
        local cached = Images.findCachedFilename(dir, norm)
        if cached then
            map[norm] = cached
        elseif want_download then
            local filename = Images.filenameForUrl(norm)
            jobs[#jobs + 1] = { url = norm, dir = dir, filename = filename }
            job_urls[#job_urls + 1] = norm
        else
            missing = missing + 1
        end
    end

    if #jobs > 0 then
        local results = Images.downloadMany(jobs, {
            max_parallel = opts.max_parallel or Images.readMaxParallel(),
            serial = opts.serial,
            on_progress = opts.on_progress,
        })
        for i, result in ipairs(results) do
            local norm = job_urls[i]
            if result and result.ok then
                -- Prefer on-disk name (handles magic-byte extension corrections).
                map[norm] = Images.findCachedFilename(dir, norm) or result.filename
                downloaded = downloaded + 1
            else
                missing = missing + 1
            end
        end
    end
    return map, dir, downloaded, missing
end

---Cached-only map (no network) for fast first paint.
function Images.cachedMap(html, data_dir)
    local dir = Images.directory(data_dir)
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    local map = {}
    if not lfs_ok then return map, Images.absoluteDirectory(dir) end
    if lfs.attributes(dir, "mode") ~= "directory" then
        return map, Images.absoluteDirectory(dir)
    end
    for _, url in ipairs(Images.extractImageUrls(html)) do
        local norm = Images.normalizeUrl(url)
        local filename = Images.findCachedFilename(dir, norm)
        if filename then
            map[norm] = filename
        end
    end
    return map, Images.absoluteDirectory(dir)
end

---Collect image filenames referenced by articles currently in cache.
function Images.referencedFilenames(cache)
    local keep = {}
    if not cache or not cache.listByMode then return keep end
    local dir = Images.directory(cache.root)
    for _, item in ipairs(cache:listByMode("all")) do
        local article = cache:getArticle(item.id)
        if article and article.html and article.html ~= "" then
            for _, url in ipairs(Images.extractImageUrls(article.html, 50)) do
                local name = Images.findCachedFilename(dir, url) or Images.filenameForUrl(url)
                if name then keep[name] = true end
            end
        end
    end
    return keep
end

---Delete orphan image files not in keep set. Returns number removed.
function Images.purgeOrphans(data_dir, keep)
    keep = keep or {}
    local dir = Images.directory(data_dir)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then return 0 end
    local removed = 0
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." and not name:match("%.tmp$") then
            if not keep[name] then
                local path = dir .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "file" then
                    os.remove(path)
                    removed = removed + 1
                end
            end
        end
    end
    return removed
end

return Images
