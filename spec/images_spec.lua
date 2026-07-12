package.path = "./freshrss.koplugin/?.lua;./?.lua;" .. package.path

local helpers = dofile("./spec/helpers.lua")
helpers.install_lfs()

local settings_store = {}
_G.G_reader_settings = {
    readSetting = function(_, key) return settings_store[key] end,
    saveSetting = function(_, key, value) settings_store[key] = value end,
    delSetting = function(_, key) settings_store[key] = nil end,
    flush = function() end,
}

-- Enrich lfs stub with attributes for cache checks.
do
    local lfs = require("libs/libkoreader-lfs")
    local orig_mkdir = lfs.mkdir
    function lfs.attributes(path, mode)
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
    end
    lfs.mkdir = orig_mkdir
end

local Images = dofile("./freshrss.koplugin/images.lua")

describe("FreshRSS images helpers", function()
    before_each(function()
        settings_store = {}
    end)
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

    it("exposes a bounded parallel download limit", function()
        assert.are.equal(3, Images.MAX_PARALLEL)
    end)

    it("downloadMany runs jobs serially when requested and reports progress", function()
        local calls = {}
        local progress = {}
        local orig = Images.downloadOne
        Images.downloadOne = function(url, dir, filename)
            table.insert(calls, { url = url, dir = dir, filename = filename })
            return true, filename
        end
        local results, downloaded = Images.downloadMany({
            { url = "https://a/1.png", dir = "/tmp", filename = "a.png" },
            { url = "https://b/2.png", dir = "/tmp", filename = "b.png" },
            { url = "https://c/3.png", dir = "/tmp", filename = "c.png" },
        }, {
            serial = true,
            on_progress = function(done, total, result)
                table.insert(progress, { done = done, total = total, ok = result.ok })
            end,
        })
        Images.downloadOne = orig
        assert.are.equal(3, #calls)
        assert.are.equal(3, downloaded)
        assert.are.equal(3, #results)
        assert.is_true(results[1].ok)
        assert.are.equal("a.png", results[1].filename)
        assert.are.equal(3, #progress)
        assert.are.equal(3, progress[3].total)
    end)

    it("downloadMany respects max_success in serial mode", function()
        local calls = 0
        local orig = Images.downloadOne
        Images.downloadOne = function(url, dir, filename)
            calls = calls + 1
            return true, filename
        end
        local results, downloaded = Images.downloadMany({
            { url = "https://a/1.png", dir = "/tmp", filename = "a.png" },
            { url = "https://b/2.png", dir = "/tmp", filename = "b.png" },
            { url = "https://c/3.png", dir = "/tmp", filename = "c.png" },
        }, { serial = true, max_success = 2 })
        Images.downloadOne = orig
        assert.are.equal(2, calls)
        assert.are.equal(2, downloaded)
        assert.is_true(results[1].ok)
        assert.is_true(results[2].ok)
        assert.is_false(results[3].ok)
    end)

    it("prepare uses downloadMany for missing images", function()
        local seen = {}
        local orig_many = Images.downloadMany
        Images.downloadMany = function(jobs, opts)
            seen.jobs = jobs
            seen.opts = opts
            local results = {}
            for i, job in ipairs(jobs) do
                results[i] = { ok = true, url = job.url, filename = job.filename }
            end
            return results, #results
        end
        local html = [[<img src="https://a/1.png"><img src="https://b/2.jpg">]]
        local map, dir, downloaded, missing = Images.prepare(html, {
            data_dir = "/tmp/freshrss-img-test",
            download = true,
            is_online = true,
            serial = true,
        })
        Images.downloadMany = orig_many
        assert.are.equal(2, #seen.jobs)
        assert.are.equal(2, downloaded)
        assert.are.equal(0, missing)
        assert.truthy(map["https://a/1.png"])
        assert.truthy(map["https://b/2.jpg"])
        assert.truthy(dir:find("images", 1, true))
    end)

    it("downloadMany falls back to serial when parallel yields zero successes", function()
        local serial_calls = 0
        local orig_one = Images.downloadOne
        Images.downloadOne = function(url, dir, filename)
            serial_calls = serial_calls + 1
            return true, filename
        end
        local results, downloaded = Images.downloadMany({
            { url = "https://a/1.png", dir = "/tmp", filename = "a.png" },
            { url = "https://b/2.png", dir = "/tmp", filename = "b.png" },
        }, { max_parallel = 3 })
        Images.downloadOne = orig_one
        -- Parallel either errors/returns 0 (then serial) or is unavailable (serial).
        assert.are.equal(2, serial_calls)
        assert.are.equal(2, downloaded)
        assert.is_true(results[1].ok)
        assert.is_true(results[2].ok)
    end)

    it("absoluteDirectory keeps absolute paths unchanged", function()
        assert.are.equal("/tmp/freshrss/images", Images.absoluteDirectory("/tmp/freshrss/images"))
    end)

    it("prepare prefers on-disk filename after extension correction", function()
        local data_dir = "/tmp/freshrss-prepare-ext"
        os.execute("rm -rf " .. data_dir)
        local html = [[<img src="https://cdn/pic.jpg">]]
        local norm = "https://cdn/pic.jpg"
        local preferred = Images.filenameForUrl(norm)
        local base = preferred:match("^(.*)%.[^%.]+$")
        local corrected = base .. ".png"
        local orig_many = Images.downloadMany
        Images.downloadMany = function(jobs)
            local imgdir = jobs[1].dir
            local path = imgdir .. "/" .. corrected
            local f = assert(io.open(path, "wb"))
            f:write("\x89PNG\r\n\x1a\nxxxx")
            f:close()
            return { { ok = true, url = jobs[1].url, filename = corrected } }, 1
        end
        local map, out_dir, downloaded = Images.prepare(html, {
            data_dir = data_dir,
            download = true,
            is_online = true,
            serial = true,
        })
        Images.downloadMany = orig_many
        assert.are.equal(1, downloaded)
        assert.are.equal(corrected, map[norm])
        local rewritten = Images.rewriteHtml(html, map)
        assert.truthy(rewritten:find('src="' .. corrected .. '"', 1, true))
        assert.falsy(rewritten:find("%[image%]"))
        assert.truthy(out_dir:find("images", 1, true))
    end)

    it("reads and cycles image setting caps", function()
        assert.are.equal(10, Images.readMaxImages())
        assert.are.equal(50, Images.readSyncBudget())
        assert.are.equal(3, Images.readMaxParallel())
        assert.are.equal(15, Images.cycleMaxImages())
        assert.are.equal(15, Images.readMaxImages())
        assert.are.equal(100, Images.cycleSyncBudget())
        assert.are.equal(1, Images.cycleMaxParallel())
        assert.are.equal(2, Images.cycleMaxParallel())
        -- Cap extractImageUrls to settings
        local html = ""
        for i = 1, 20 do
            html = html .. string.format('<img src="https://ex/%d.png">', i)
        end
        settings_store[Images.SETTING_MAX_IMAGES] = 5
        assert.are.equal(5, #Images.extractImageUrls(html))
        assert.are.equal(3, #Images.extractImageUrls(html, 3))
    end)

    it("cycles image max bytes and timeout profiles", function()
        assert.are.equal(1024 * 1024, Images.readMaxBytes())
        assert.are.equal("default", Images.readTimeoutProfile())
        local c, t = Images.readTimeouts()
        assert.are.equal(5, c)
        assert.are.equal(12, t)
        assert.are.equal(2 * 1024 * 1024, Images.cycleMaxBytes())
        assert.are.equal("long", Images.cycleTimeoutProfile())
        c, t = Images.readTimeouts()
        assert.are.equal(10, c)
        assert.are.equal(25, t)
    end)

    it("purges orphan image files not referenced by keep set", function()
        local data_dir = os.tmpname()
        os.remove(data_dir)
        local lfs = require("libs/libkoreader-lfs")
        lfs.mkdir(data_dir)
        local imgdir = Images.ensureDirectory(Images.directory(data_dir))
        local keep_name = "keep.png"
        local drop_name = "drop.png"
        local kf = assert(io.open(imgdir .. "/" .. keep_name, "wb"))
        kf:write("keep")
        kf:close()
        local df = assert(io.open(imgdir .. "/" .. drop_name, "wb"))
        df:write("drop")
        df:close()
        local removed = Images.purgeOrphans(data_dir, { [keep_name] = true })
        assert.are.equal(1, removed)
        assert.truthy(io.open(imgdir .. "/" .. keep_name, "r"))
        assert.is_nil(io.open(imgdir .. "/" .. drop_name, "r"))
    end)
end)
