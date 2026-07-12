# AGENTS.md — FreshRSS for KOReader

Offline-first KOReader plugin that reads FreshRSS via the Google Reader–compatible API. Local cache opens immediately; sync/prefetch runs in the background. Current plugin version is in `freshrss.koplugin/_meta.lua` (e.g. v0.9.1). Remote: `https://github.com/monk-blade/freshrss-koreader.git`.

## What to edit

| Path | Role |
|------|------|
| `freshrss.koplugin/` | **Source of truth** — edit here |
| `spec/` | Busted unit/integration specs |
| `koreader/` | Local KOReader checkout (gitignored). Plugin is symlinked as `koreader/plugins/freshrss.koplugin` → `../../freshrss.koplugin` |

Do **not** edit KOReader core unless the task explicitly requires it. After changing plugin Lua, the symlink means the emulator picks up changes without copying.

Install for devices: copy `freshrss.koplugin` into KOReader’s `plugins/` and restart.

## Architecture

```
API (api.lua) → Sync (sync.lua) → Cache (cache.lua)
                                      ↓
                              Home list (home.lua)
                                      ↓
                         Article viewer (renderer.lua)
                                      ↑
                    Images prefetch + rewrite (images.lua)
```

- **`main.lua`** — plugin entry: settings, Dispatcher hooks, menus, sync orchestration, opens home/viewer.
- **`api.lua`** — GReader API client (login, stream ids/contents, batched mark/star, etc.).
- **`sync.lua`** — id enumeration → contents for cache misses; optional image prefetch; batched pending-action queue flush.
- **`cache.lua`** — on-disk article index under KOReader data dir `freshrss/`.
- **`home.lua`** — full-screen home (TitleBar + favorites/actions row + nested article `Menu`).
- **`renderer.lua`** — `ScrollHtmlWidget` viewer (fonts, line height, images, whitespace sanitize, hold-to-dictionary via `ReaderDictionary`).
- **`fav_categories.lua`** / **`settings_ui.lua`** — favorite category chips and icon Settings/View panels.
- **`list_fonts.lua`** — Latin Menu face + Gujarati Font.fallbacks while home is open.
- **`list_format.lua`** — short published dates and feed unread-count helpers for list rows.
- **`nav.lua`** — stable Prev/Next against an id snapshot.
- **`ui_status.lua`** — top sync progress strip.
- **`icons.lua`** / **`assets/`** — Lucide + FreshRSS icons.

Flow: sync populates cache → home lists by browse mode → open article builds HTML → images rewrite to **relative filenames**; viewer sets `html_resource_directory` to the article image dir so MuPDF resolves them via its directory archive.

## Images / MuPDF (critical)

MuPDF **cannot** fetch remote HTTP(S) images. Prefetch during sync (and on open as needed), then rewrite tags.

- Emit **relative** filenames only (e.g. `a1b2c3d4.jpg`), **not** `file://` absolute URLs — MuPDF uses `html_resource_directory` as a directory archive.
- Always run image URLs through `Images.normalizeUrl` (`&amp;` → `&`, protocol-relative `//` → `https:`) so hash keys and rewrite maps stay consistent.
- Cap/size limits live in `images.lua` (`MAX_IMAGES`, `MAX_BYTES`, timeouts).

## Coding conventions

- Match existing Lua style in `freshrss.koplugin/` (local modules via `dofile`, KOReader widgets, gettext where already used).
- Prefer **minimal, focused diffs**. No drive-by refactors or unrelated cleanup.
- Do **not** commit unless the user explicitly asks.
- Never commit `.env` or credentials. Env vars `FRESHRSS_API_URL`, `FRESHRSS_USERNAME`, `FRESHRSS_API_PASSWORD` override settings and are not written to device settings.

## Testing

Specs under `spec/` use Busted. Helpers stub `json` / `lfs` so many tests run without a full KOReader build.

```sh
# From an activated KOReader env (see README / kodev activate), or any busted that can load the specs:
FRESHRSS_LIVE_TEST=0 busted -v /path/to/freshrss-koreader/spec
```

- `FRESHRSS_LIVE_TEST=0` (default for CI/local): no live server.
- `FRESHRSS_LIVE_TEST=1`: hits a real FreshRSS instance using env credentials; does not print the password.

Copy `.env.example` → `.env` for local credentials (gitignored).

## Pitfalls

1. **MuPDF images** — remote `src` will not load; must prefetch + relative rewrite + `html_resource_directory`. Do not “fix” display by switching to `file://` without verifying MuPDF behavior.
2. **Status strip / UI refresh** — `ui_status.lua` uses `UIManager:show` / `setDirty` / `forceRePaint`. Avoid racing strip updates with home rebuilds; close the strip when sync ends or home closes.
3. **Nested `Menu` `close_callback`** — home’s article list `Menu` must keep `close_callback = nil` (and clear Close key). Only the home title-bar X / Back should exit the plugin; nested menu close must not dismiss home.
4. **HTML entity URLs** — feed HTML often has `&amp;` in image URLs; normalize before hashing, downloading, and map lookups or images silently miss the cache.

## Out of scope for agents

Do not paste large GReader API reference into docs or comments. Prefer reading `api.lua` / existing call sites when extending the client.
