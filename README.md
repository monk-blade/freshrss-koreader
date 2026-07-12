# FreshRSS for KOReader

A lightweight KOReader plugin for reading FreshRSS feeds through the FreshRSS Google Reader-compatible API.

## Features

- Offline-first: opens the local cache immediately (no hang on launch)
- Background sync with a progress strip (login → feeds → articles → cache)
- Auto-refresh on open (toggle in the FreshRSS menu; default on)
- Unread / favorite state with offline retry queue
- Native text article view (`TextViewer`) with multiline titles
- Lucide icons for refresh and chrome (ISC-licensed)

## Installation

Copy `freshrss.koplugin` into the `plugins` directory of your KOReader installation, then restart KOReader.

In FreshRSS, enable API access and create an API password under the user profile. Enter the full API address shown by FreshRSS, for example:

```text
https://reader.example/api/greader.php
```

## Usage

1. **Tools → FreshRSS** — shows cached articles right away.
2. If online and auto-refresh is enabled, a progress strip syncs in the background.
3. Tap **Refresh** (or the title-bar refresh icon) for an explicit sync (may prompt for Wi‑Fi).
4. Toggle **Auto-refresh on open** from the list menu.

## Development and tests

The plugin accepts `FRESHRSS_API_URL`, `FRESHRSS_USERNAME`, and `FRESHRSS_API_PASSWORD` environment variables. Environment values override local KOReader settings and are not written to the device settings file. Copy `.env.example` to `.env`, populate it locally, and export it before testing; `.env` is ignored by Git.

For a local KOReader checkout, follow the official [Building.md](https://github.com/koreader/koreader/blob/master/doc/Building.md) workflow. The relevant commands are:

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
