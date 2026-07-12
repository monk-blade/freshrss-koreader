package.path = "./freshrss.koplugin/?.lua;./?.lua;" .. package.path

local helpers = dofile("./spec/helpers.lua")
helpers.install_lfs()

-- Enrich lfs stub with attributes for cache checks.
do
    local lfs = require("libs/libkoreader-lfs")
    local orig_mkdir = lfs.mkdir
    function lfs.attributes(path, mode)
        local f = io.open(path, "r")
        if f then
            local size = f:seek("end")
            f:close()
            if mode == "mode" then return "file" end
            return { mode = "file", size = size }
        end
        -- directory probe via trailing check / known mkdir
        if mode == "mode" then
            local ok = os.execute(string.format('test -d %q', path))
            if ok == true or ok == 0 then return "directory" end
            return nil
        end
        local ok = os.execute(string.format('test -d %q', path))
        if ok == true or ok == 0 then
            return { mode = "directory", size = 0 }
        end
        return nil
    end
    lfs.mkdir = orig_mkdir
end

local Images = dofile("./freshrss.koplugin/images.lua")

describe("FreshRSS images helpers", function()
    it("hashes URLs stably", function()
        local a = Images.hashUrl("https://example.com/a.png")
        local b = Images.hashUrl("https://example.com/a.png")
        local c = Images.hashUrl("https://example.com/b.png")
        assert.are.equal(a, b)
        assert.are_not.equal(a, c)
        assert.truthy(a:match("^%x+$"))
    end)

    it("picks extensions from URLs", function()
        assert.are.equal("png", Images.extensionForUrl("https://x/y/z.PNG"))
        assert.are.equal("jpg", Images.extensionForUrl("https://x/y/z.jpeg?w=1"))
        assert.are.equal("jpg", Images.extensionForUrl("https://x/y/z.bin"))
    end)

    it("extracts http(s) img srcs and caps count", function()
        local html = [[
            <p>x</p>
            <img src="https://a/1.png">
            <img src='http://b/2.jpg'>
            <img src="//c/3.webp">
            <img src="data:image/png;base64,xx">
            <img src="/relative.png">
        ]]
        local urls = Images.extractImageUrls(html)
        assert.are.equal(3, #urls)
        assert.are.equal("https://a/1.png", urls[1])
        assert.are.equal("http://b/2.jpg", urls[2])
        assert.are.equal("https://c/3.webp", urls[3])
    end)

    it("rewrites downloaded images and placeholders others", function()
        local html = [[<p>Hi</p><img src="https://a/1.png"><img src="https://b/2.png">]]
        local out = Images.rewriteHtml(html, { ["https://a/1.png"] = "abc.png" })
        assert.truthy(out:find('src="abc.png"', 1, true))
        assert.truthy(out:find("%[image%]"))
        assert.falsy(out:find("https://b/2.png", 1, true))
        assert.truthy(out:find("Hi", 1, true))
    end)

    it("filenameForUrl includes hash and extension", function()
        local name = Images.filenameForUrl("https://cdn.example/pic.PNG")
        assert.truthy(name:match("^%x+%.png$"))
    end)
end)
