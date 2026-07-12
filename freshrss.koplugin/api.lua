local json = require("json")
local http = require("socket.http")
local url = require("socket.url")
local ltn12 = require("ltn12")
local socketutil

local API = {}
API.__index = API

local function slash(value)
    return (value or ""):gsub("/+$", "")
end

function API:new(config)
    local o = setmetatable({}, self)
    o.base_url = slash(config.base_url)
    o.username = config.username
    o.api_password = config.api_password
    o.auth = config.auth
    o.token = config.token
    if not o.base_url:match("greader%.php$") then o.base_url = o.base_url .. "/api/greader.php" end
    return o
end

function API:requestRaw(path, method, fields)
    socketutil = socketutil or require("socketutil")
    local body = fields and self:encodeFields(fields) or nil
    local response = {}
    local headers = { ["Authorization"] = self.auth and ("GoogleLogin auth=" .. self.auth) or nil }
    if body then headers["content-type"] = "application/x-www-form-urlencoded" end
    socketutil:set_timeout(15, 30)
    local ok, code = http.request{ url = self.base_url .. "/" .. path, method = method or "GET", headers = headers, source = body and ltn12.source.string(body) or nil, sink = socketutil.table_sink(response) }
    socketutil:reset_timeout()
    if not ok or tonumber(code or 0) >= 400 then return nil, "HTTP request failed (" .. tostring(code) .. ")" end
    return table.concat(response), tonumber(code or 0)
end

function API:request(path, method, fields)
    local text, code = self:requestRaw(path, method, fields)
    if not text or code >= 400 then return nil, "HTTP request failed (" .. tostring(code) .. ")" end
    local decoded, err = json.decode(text)
    if not decoded then return nil, err or "Invalid JSON response" end
    return decoded
end

function API:requestAsync(path, method, fields, callback, raw)
    local UIManager = require("ui/uimanager")
    UIManager:initLooper()
    if not UIManager.looper then
        -- Emulator / builds without Turbo: fall back to blocking luasocket.
        if raw then
            local text, code = self:requestRaw(path, method, fields)
            if not text or (code and code >= 400) then
                callback(nil, "HTTP request failed (" .. tostring(code) .. ")")
            else
                callback(text, nil)
            end
            return
        end
        local decoded, err = self:request(path, method, fields)
        if not decoded then callback(nil, err) else callback(decoded) end
        return
    end
    local HTTPClient = require("httpclient")
    local body = fields and self:encodeFields(fields) or nil
    local headers = { ["Authorization"] = self.auth and ("GoogleLogin auth=" .. self.auth) or nil }
    if body then headers["content-type"] = "application/x-www-form-urlencoded" end
    HTTPClient:new():request({
        url = self.base_url .. "/" .. path,
        method = method or "GET",
        body = body,
        on_headers = function(response_headers)
            for key, value in pairs(headers) do if value then response_headers:add(key, value) end end
        end,
    }, function(response)
        if not response or tonumber(response.code or response.status or 0) >= 400 then
            callback(nil, "HTTP request failed")
            return
        end
        if raw then callback(response.body or "", nil); return end
        local decoded, err = json.decode(response.body or "")
        if not decoded then callback(nil, err or "Invalid JSON response") else callback(decoded) end
    end)
end

function API:loginAsync(callback)
    if self.auth and self.token then callback(true); return end
    self:requestAsync("accounts/ClientLogin", "POST", { Email = self.username, Passwd = self.api_password }, function(text, error_message)
        if error_message then callback(false, error_message); return end
        self.auth = text:match("Auth=([^%s]+)")
        if not self.auth then callback(false, "FreshRSS did not return an authentication token"); return end
        self:requestAsync("reader/api/0/token", nil, nil, function(token, token_error)
            if token_error then callback(false, token_error); return end
            self.token = token:gsub("%s+$", "")
            callback(true)
        end, true)
    end, true)
end

function API:encodeFields(fields)
    local parts = {}
    for key, value in pairs(fields) do table.insert(parts, tostring(key) .. "=" .. url.escape(tostring(value))) end
    return table.concat(parts, "&")
end

function API:login()
    if self.auth and self.token then return true end
    local text, code = self:requestRaw("accounts/ClientLogin", "POST", { Email = self.username, Passwd = self.api_password })
    if not text or code >= 400 then return false, "Invalid login response (" .. tostring(code) .. ")" end
    self.auth = text:match("Auth=([^%s]+)")
    if not self.auth then return false, "FreshRSS did not return an authentication token" end
    local token_text = self:requestRaw("reader/api/0/token")
    self.token = token_text and token_text:gsub("%s+$", "") or nil
    if not self.token or self.token == "" then
        self.auth = nil
        return false, "FreshRSS did not return a write token"
    end
    return true
end

function API:invalidateSession()
    self.auth = nil
    self.token = nil
end

function API:listSubscriptions()
    return self:request("reader/api/0/subscription/list?output=json")
end

function API:listTags()
    return self:request("reader/api/0/tag/list?output=json")
end

function API:unreadCount()
    return self:request("reader/api/0/unread-count?output=json")
end

function API:stream(stream_id, count)
    return self:request("reader/api/0/stream/contents/" .. (stream_id or "user/-/state/com.google/reading-list") .. "?output=json&n=" .. tostring(count or 100) .. "&r=newest")
end

function API:editTag(item_id, action, state)
    if not self.token then
        local token = self:requestRaw("reader/api/0/token")
        self.token = token and token:gsub("%s+$", "")
    end
    local tag = "user/-/state/com.google/" .. action
    local field = state and "a" or "r"
    local text, code = self:requestRaw("reader/api/0/edit-tag", "POST", { i = item_id, [field] = tag, T = self.token or "" })
    if not text or code >= 400 then return false, "HTTP request failed (" .. tostring(code) .. ")" end
    return true
end

return API
