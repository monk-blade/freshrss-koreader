# FreshRSS for KOReader

A lightweight KOReader plugin for reading FreshRSS feeds through the FreshRSS Google Reader-compatible API.

## Features

- Offline-first: opens the local cache immediately (no hang on launch)
- Full-screen home with FreshRSS brand mark (tap to sync) and icon action bar (**Browse / Mark all / Settings**)
- Denser article list: unread/star markers, **feed · post time** on each row (no keyboard shortcut letters), single-line titles; restores list page after closing an article
- Browse modes: All / Unread / Starred / Feeds / Categories (Feeds and Categories show **unread counts** from last sync)
- **List sort** (newest / oldest) and **hide feeds** (long-press a feed; hidden feeds stay out of All/Unread)
- **Sync scope**: current browse view (default) or always reading list; sync toast names the stream
- **Cache retention**: max retained articles (500–5000), auto-evict oldest non-starred after sync, Clean cache now, approximate cache size in Settings
- Grouped Settings: Connection / Sync / Cache / Appearance / Images / Queue
- **Mark read on open** (default on); turn off to leave articles unread when opening
- **List fonts**: Latin (e.g. Roboto Condensed) + Gujarati fallback (e.g. Noto Serif Gujarati) — install fonts in KOReader’s fonts folder, then pick under Appearance; **List font size** SpinWidget
- Auto-refresh on open **off by default** (opt-in under Connection)
- Background sync with a progress strip; pending queue is flushed **before** fetching articles
- Unread-only sync by default (`xt=read`), with optional “all articles” mode
- Configurable articles-per-sync cap (50 / 100 / 200 / 300) with continuation paging
- Tunable image sync: images per article, sync budget, parallelism, max bytes, timeout profile
- Mark all as read for the current browse stream
- HTML article viewer with **View settings** (☰: body/title font size, line height / spacing, images, justify) and icon bar: Prev / Unread / Favorite / **Open original** / Next; session scroll position remembered when leaving an article
- Same viewer body/title font size, line height, and spacing also under Settings → Appearance
- Local image download into the cache (MuPDF never fetches remote URLs); orphan images purged when cache is cleaned
- Favorite / Mark unread with live button state; favorited articles are **pinned on disk** under `favorites/`
- Pending-action queue UI (human-readable rows / flush / clear) with sync summary toast
- Dispatcher actions: `freshrss_sync`, `freshrss_flush_queue`, `freshrss_open`
- Lucide + FreshRSS SVG icons (ISC-licensed Lucide assets)

## Installation

Copy `freshrss.koplugin` into the `plugins` directory of your KOReader installation, then restart KOReader.

In FreshRSS, enable API access and create an API password under the user profile. Enter the full API address shown by FreshRSS, for example:

```text
https://reader.example/api/greader.php
```

For clearer mixed-script article lists, install **Roboto Condensed** and **Noto Serif Gujarati** into KOReader’s fonts directory, then set them under **Settings → Appearance → List font (Latin / Gujarati)**.

## Usage

1. **Tools → FreshRSS** — full-screen list of cached articles (Unread by default). Only the home title-bar **X** (or Back on the list) exits the plugin; closing an article returns to the list (same page).
2. Tap the **FreshRSS mark** (left of the title) to sync the current view (or reading list if that scope is set). Tap **Browse** (filter icon) to switch All / Unread / Starred / Feeds / Categories.
3. Auto-refresh on open is **off** by default (enable under Settings → Connection). Use **Mark read on open** to control whether opening marks articles read.
4. Use the icon bar under the title (**filter** = Browse, **check** = Mark all, **gear** = Settings). Browse mode stays in the title. Long-press a feed in Feeds to hide/unhide it from All/Unread.
5. In an article: tap the **☰** menu for View settings; use the icon bar for Prev / Mark unread / Favorite / Open original / Next.

## Development and tests

The plugin accepts `FRESHRSS_API_URL`, `FRESHRSS_USERNAME`, and `FRESHRSS_API_PASSWORD` environment variables. Environment values override local KOReader settings and are not written to the device settings file. Copy `.env.example` to `.env`, populate it locally, and export it before testing; `.env` is ignored by Git.

For a local KOReader checkout, follow the official [Building.md](https://github.com/koreader/koreader/doc/Building.md) workflow. The relevant commands are:

```sh
cd /path/to/koreader
./kodev fetch-thirdparty
./kodev build
./kodev activate
```

Then run the plugin’s unit tests with the activated KOReader Lua/Busted environment:

```sh
FRESHRSS_LIVE_TEST=0 busted -v /path/to/freshrss-koreader/spec
```

To exercise a real FreshRSS server, set `FRESHRSS_LIVE_TEST=1`. The live test performs login, subscription, unread-count, and stream requests; it never prints the password.

## License

The plugin is licensed under AGPL-3.0-or-later. Third-party assets are listed in `THIRD_PARTY_LICENSES.md`.
