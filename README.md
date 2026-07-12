# FreshRSS for KOReader

A lightweight KOReader plugin for reading FreshRSS feeds through the FreshRSS Google Reader-compatible API.

## Features

- Offline-first: opens the local cache immediately (no hang on launch)
- Full-screen home with icon action bar (**Browse / Mark all / Settings**)
- Browse modes: All / Unread / Starred / Feeds / Categories
- Separate Settings menu (connection, auto-refresh, sync filter, articles per sync, queue)
- Auto-refresh on open **off by default** (opt-in in Settings)
- Background sync with a progress strip when you refresh
- Unread-only sync by default (`xt=read`), with optional “all articles” mode
- Configurable articles-per-sync cap (50 / 100 / 200 / 300) with continuation paging
- Mark all as read for the current browse stream
- HTML article viewer with **View settings** (☰: font size/face, line height, show images, open original link)
- Local image download into the cache (MuPDF never fetches remote URLs); images prefetch during sync (up to 50 per sync) with bounded parallel downloads (v0.4.3) and rewrite to relative filenames loaded via MuPDF’s `html_resource_directory` (v0.4.2 fixed broken `file://` rewrites)
- Favorite / Mark unread with live button state and sync or “queued offline” notifications
- Pending-action queue UI (list / flush / clear) with sync summary toast
- Dispatcher actions: `freshrss_sync`, `freshrss_flush_queue`, `freshrss_open`
- Lucide icons for refresh and chrome (ISC-licensed)

## Installation

Copy `freshrss.koplugin` into the `plugins` directory of your KOReader installation, then restart KOReader.

In FreshRSS, enable API access and create an API password under the user profile. Enter the full API address shown by FreshRSS, for example:

```text
https://reader.example/api/greader.php
```

## Usage

1. **Tools → FreshRSS** — full-screen list of cached articles (Unread by default). Only the home title-bar **X** (or Back on the list) exits the plugin; closing an article returns to the list.
2. Tap **Browse** to switch All / Unread / Starred / Feeds / Categories.
3. Tap the title-bar refresh icon to sync the current stream (may prompt for Wi‑Fi). Auto-refresh on open is **off** by default (enable under Settings).
4. Use the icon bar under the title (**filter** = Browse, **check** = Mark all, **gear** = Settings). Browse mode stays in the title.
5. In an article: tap the **☰** menu for View settings (font, size, line height, images, original link); swipe/tap to page; use the icon bar for Prev / Mark unread / Favorite / Next (Favorite toggles outline ↔ filled star; toast shows synced vs queued).

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
