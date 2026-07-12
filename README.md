# FreshRSS for KOReader

A lightweight KOReader plugin for reading FreshRSS feeds through the FreshRSS Google Reader-compatible API.

## Features

- Feed/article browsing with unread and favorite state
- Native text-first article view
- Custom KOReader-native article layout using the device's configured `ffont`, `tfont`, and `smallinfofont` faces
- Persistent local article cache
- Offline retry queue for read and favorite actions
- Parallel async sync for subscriptions, tags, unread counts, and article streams
- Optional image support planned behind a settings toggle

## Installation

Copy `freshrss.koplugin` into the `plugins` directory of your KOReader installation, then restart KOReader.

In FreshRSS, enable API access and create an API password under the user profile. Enter the full API address shown by FreshRSS, for example:

```text
https://reader.example/api/greader.php
```

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
