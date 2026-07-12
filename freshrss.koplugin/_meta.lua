local _ = require("gettext")
return {
    name = "freshrss",
    fullname = _("FreshRSS"),
    description = _([[Browse FreshRSS offline-first (v0.6.0). Reliable offline reading: cache retention/eviction with starred preserve and orphan image GC, mark-read-on-open toggle, Open original in the viewer, queue flush at sync start, denser dated list, feed unread counts, Latin/Gujarati list fonts, tunable image sync (count/budget/parallel/size/timeouts), and Dispatcher hooks. Auto-refresh on open is off by default.]]),
}
