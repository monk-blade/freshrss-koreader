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

    it("maps content-type to extensions", function()
        assert.are.equal("png", Images.extensionFromContentType("image/png"))
        assert.are.equal("jpg", Images.extensionFromContentType("image/jpeg; charset=binary"))
        assert.is_nil(Images.extensionFromContentType("text/html"))
    end)

    it("validates image magic bytes and rejects HTML", function()
        assert.truthy(Images.isValidImageData("\xFF\xD8\xFF\xE0xxxx"))
        assert.truthy(Images.isValidImageData("\x89PNG\r\n\x1a\nxxxx"))
        assert.truthy(Images.isValidImageData("GIF89axxxx"))
        assert.truthy(Images.isValidImageData("RIFF....WEBP...."))
        assert.truthy(Images.isValidImageData("<svg xmlns='http://www.w3.org/2000/svg'></svg>"))
        assert.falsy(Images.isValidImageData("<!DOCTYPE html><html></html>"))
        assert.falsy(Images.isValidImageData("<html><body>error</body></html>"))
        assert.falsy(Images.isValidImageData("not an image"))
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

    it("extracts data-src lazy-load URLs", function()
        local html = [[<img src="placeholder.gif" data-src="https://cdn/real.png">]]
        local urls = Images.extractImageUrls(html)
        assert.are.equal(1, #urls)
        assert.are.equal("https://cdn/real.png", urls[1])

        local html2 = [[<img data-src="https://cdn/only.png">]]
        local urls2 = Images.extractImageUrls(html2)
        assert.are.equal(1, #urls2)
        assert.are.equal("https://cdn/only.png", urls2[1])
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

    it("normalizeUrl decodes HTML entities and protocol-relative URLs", function()
        assert.are.equal("https://a/b?x=1&y=2", Images.normalizeUrl("https://a/b?x=1&amp;y=2"))
        assert.are.equal("https://c/d.png", Images.normalizeUrl("//c/d.png"))
        assert.are.equal('https://x/"q"', Images.normalizeUrl("https://x/&quot;q&quot;"))
    end)

    it("dedupes extractImageUrls by normalized URL", function()
        local html = [[
            <img src="https://a/b?x=1&amp;y=2">
            <img src="https://a/b?x=1&y=2">
        ]]
        local urls = Images.extractImageUrls(html)
        assert.are.equal(1, #urls)
        assert.are.equal("https://a/b?x=1&y=2", urls[1])
    end)

    it("rewrites mapped images to relative filenames (not file://)", function()
        local html = [[<img src="https://a/1.png">]]
        local map = { ["https://a/1.png"] = "abc.png" }
        local out = Images.rewriteHtml(html, map, { directory = "/data/freshrss/images" })
        assert.truthy(out:find('src="abc.png"', 1, true))
        assert.falsy(out:find("file://", 1, true))
    end)

    it("rewrites HTML-entity img src via normalized map keys", function()
        local html = [[<img src="https://a/b?x=1&amp;y=2">]]
        local norm = Images.normalizeUrl("https://a/b?x=1&amp;y=2")
        local out = Images.rewriteHtml(html, { [norm] = "pic.png" }, { directory = "/cache/images" })
        assert.truthy(out:find('src="pic.png"', 1, true))
        assert.falsy(out:find("file://", 1, true))
        assert.falsy(out:find("%[image%]"))
    end)

    it("rewrites data-src images when mapped", function()
        local html = [[<img data-src="https://cdn/real.png">]]
        local out = Images.rewriteHtml(html, { ["https://cdn/real.png"] = "deadbeef.png" })
        assert.truthy(out:find('src="deadbeef.png"', 1, true))
    end)
end)
