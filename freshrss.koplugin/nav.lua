-- Ordered-list neighbor helpers for article Next/Prev.
-- Keep navigation against a stable id snapshot so mark-as-read (unread browse)
-- does not shift or drop neighbors mid-session.

local Nav = {}

---Return index, prev_id, next_id for `id` in ordered `ids`.
---index is nil when `id` is not present.
function Nav.neighbors(ids, id)
    if type(ids) ~= "table" or id == nil then
        return nil, nil, nil
    end
    local want = tostring(id)
    for i, aid in ipairs(ids) do
        if tostring(aid) == want then
            return i, ids[i - 1], ids[i + 1]
        end
    end
    return nil, nil, nil
end

return Nav
