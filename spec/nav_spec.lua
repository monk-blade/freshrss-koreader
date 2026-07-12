package.path = "./freshrss.koplugin/?.lua;./?.lua;" .. package.path
local Nav = dofile("./freshrss.koplugin/nav.lua")

describe("FreshRSS article Nav.neighbors", function()
    it("returns prev/next and index inside an ordered list", function()
        local ids = { "a", "b", "c" }
        local index, prev_id, next_id = Nav.neighbors(ids, "b")
        assert.equals(2, index)
        assert.equals("a", prev_id)
        assert.equals("c", next_id)
    end)

    it("disables prev on the first article and next on the last", function()
        local ids = { "a", "b", "c" }
        local i1, p1, n1 = Nav.neighbors(ids, "a")
        assert.equals(1, i1)
        assert.is_nil(p1)
        assert.equals("b", n1)
        local i3, p3, n3 = Nav.neighbors(ids, "c")
        assert.equals(3, i3)
        assert.equals("b", p3)
        assert.is_nil(n3)
    end)

    it("matches ids via tostring so numeric/string ids align", function()
        local index, prev_id, next_id = Nav.neighbors({ 10, 20, 30 }, "20")
        assert.equals(2, index)
        assert.equals(10, prev_id)
        assert.equals(30, next_id)
    end)

    it("returns nils when id is missing (caller should not default to index 1)", function()
        local index, prev_id, next_id = Nav.neighbors({ "a", "b" }, "missing")
        assert.is_nil(index)
        assert.is_nil(prev_id)
        assert.is_nil(next_id)
    end)

    it("keeps stable neighbors after the current id is removed from a live unread list", function()
        -- Simulates unread browse: snapshot at open, then mark-as-read mutates live list.
        local snapshot = { "a", "b", "c", "d" }
        local live_after_read = { "b", "c", "d" } -- "a" dropped

        local index, prev_id, next_id = Nav.neighbors(snapshot, "b")
        assert.equals(2, index)
        assert.equals("a", prev_id)
        assert.equals("c", next_id)

        -- Re-querying the mutated unread list would wrongly put b at index 1 with no prev.
        local bad_index, bad_prev = Nav.neighbors(live_after_read, "b")
        assert.equals(1, bad_index)
        assert.is_nil(bad_prev)
    end)
end)
