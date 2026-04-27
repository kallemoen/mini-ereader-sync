# Mini E-Reader Sync

A tiny macOS menu bar app that turns your Instapaper saves into clean EPUBs and one-click syncs them to an [XTEink X4](https://www.xteink.com/products/xteink-x4) e-reader running [CrossPoint firmware](https://github.com/crosspoint-reader/crosspoint-reader).

App also has a feature for importing epubs directly into the app. No cloud, no accounts, no database. Everything runs locally on your Mac.

To use app you need:
- Instapaper api keys
- Anthropic API key
- Firecrawl API key

> _GIF placeholder — record a 30s clip of the flow once built and drop it at `docs/screenshots/demo.gif`._

## What it does

1. Polls your Instapaper queue every 15 minutes.
2. For each new article, fetches the text, asks Claude to clean up the HTML, and builds a proper EPUB.
3. Caches EPUBs on your Mac.
4. When you connect to the reader's `E-Paper` Wi-Fi, the Sync button lights up. Click it and every unsynced article uploads to `/Books` on the reader.

```
 Instapaper API ──poll every 15m──► Mac Menu Bar App (SwiftUI MenuBarExtra)
                                         │        │       │
                           Claude API ◄──┘        │       └──► ~/Library/Application Support/MiniEreader/
                           (HTML → clean EPUB)    │              ├── library.sqlite
                                                  │              └── epubs/{id}.epub
                                                  ▼
                                        When SSID == "E-Paper":
                                        POST http://192.168.3.3/upload?path=/Books
```

## Install — Option A: Prebuilt app (recommended)

**Requirements:** macOS 14 (Sonoma) or newer.

1. Download `MiniEreader.app.zip` from the [latest release](https://github.com/kallemoen/mini-ereader-sync/releases/latest).
2. Unzip it (double-click in Finder, or `unzip MiniEreader.app.zip`).
3. Drag `MiniEreader.app` into `/Applications`.
4. **First launch — bypass Gatekeeper.** The binary is ad-hoc signed (not notarized), so macOS will refuse to open it normally. Pick one:
   - **Finder:** right-click `MiniEreader.app` → **Open** → confirm **Open** in the dialog. Only needed once.
   - **Terminal (faster):**
     ```bash
     xattr -dr com.apple.quarantine /Applications/MiniEreader.app
     open /Applications/MiniEreader.app
     ```
5. The menu bar icon (📖) appears in the top-right. Click it → **Settings** to enter credentials (see [First-run setup](#first-run-setup)).

## Install — Option B: Build from source

**Requirements:** macOS 14+, Homebrew, and either Xcode 15+ or just the Swift toolchain (`xcode-select --install`).

```bash
git clone https://github.com/kallemoen/mini-ereader-sync.git
cd mini-ereader-sync
```

Then pick one path:

**B1 — Xcode (recommended if you want to modify code):**
```bash
./scripts/bootstrap.sh           # installs xcodegen, generates the Xcode project
open mac/MiniEreader.xcodeproj   # ⌘R to build & run
```

**B2 — SwiftPM only (no Xcode required):**
```bash
./scripts/build-app.sh release   # builds build/MiniEreader.app, copies to /Applications if writable
open /Applications/MiniEreader.app
```

## First-run setup

On first launch you'll see a Settings sheet asking for:

| Secret | Where to get it |
|---|---|
| Instapaper consumer key + secret | [instapaper.com/main/request_oauth_consumer_token](https://www.instapaper.com/main/request_oauth_consumer_token) |
| Instapaper username + password | Your Instapaper login. Used once to mint an OAuth token, then discarded. |
| Anthropic API key | [console.anthropic.com](https://console.anthropic.com) |

All secrets are stored in your macOS Keychain. Nothing is ever written to disk in plaintext, and nothing leaves your Mac except the direct calls to Instapaper, Claude, and the reader itself.

## Using it

1. Save an article to Instapaper the normal way (extension/bookmarklet).
2. The menu bar icon picks it up within 15 minutes (or click Refresh).
3. Wait for the row to turn green (converted).
4. On the reader: open File Transfer, connect your Mac to the `E-Paper` Wi-Fi.
5. Click **Sync**. Done.

## Troubleshooting

**App won't open — "damaged" or "unidentified developer".** Ad-hoc signed apps need their quarantine attribute stripped:
```bash
xattr -dr com.apple.quarantine /Applications/MiniEreader.app
```

**Menu bar icon missing after install.** Run the binary directly to see logs:
```bash
/Applications/MiniEreader.app/Contents/MacOS/MiniEreader
```

**"N new" never moves.** Check Settings → Location Services is enabled for Mini E-Reader. macOS requires Location permission to read the current Wi-Fi SSID (this app never reads your actual location).

**Instapaper 401s.** The free-tier Instapaper API requires an approved consumer key/secret — apply at the link above. `username/password` is only used to mint a token on first run.

**EPUB won't open on the reader.** Try opening the cached `.epub` in Books.app first. If that renders fine but the reader rejects it, check `GET http://192.168.3.3/api/status` — the reader wants `/Books` to exist (the app creates it on first upload).

**Claude rate limits.** Conversion runs at concurrency 2. If you hit 429s, wait — failed rows stay as `error` and can be retried from the row menu.

## For AI assistants helping someone install this

If a user has handed you this repo and asked you to install it, follow this checklist deterministically:

1. **Confirm platform.** Run `sw_vers -productVersion` — it must report `14.x` or higher. Bail out with a clear message if not (the app is macOS-only and uses APIs that don't exist on older versions).
2. **Pick a path.**
   - If the user just wants to *use* the app → **Option A** (prebuilt).
   - If they want to read or modify the source → **Option B**.
3. **Option A (prebuilt) — exact sequence:**
   1. Open the [latest release](https://github.com/kallemoen/mini-ereader-sync/releases/latest), download `MiniEreader.app.zip`.
   2. `unzip ~/Downloads/MiniEreader.app.zip -d ~/Downloads/` and `mv ~/Downloads/MiniEreader.app /Applications/`.
   3. Strip quarantine: `xattr -dr com.apple.quarantine /Applications/MiniEreader.app`.
   4. Launch: `open /Applications/MiniEreader.app`.
   5. Tell the user to look for the 📖 icon in the menu bar (top-right), click it, then **Settings**.
4. **Option B (build from source) — exact sequence:**
   1. `git clone https://github.com/kallemoen/mini-ereader-sync.git && cd mini-ereader-sync`
   2. Try `./scripts/bootstrap.sh` first. If `xcodegen` install fails (e.g., no Homebrew), fall back to `./scripts/build-app.sh release`.
   3. After either path: `open /Applications/MiniEreader.app` (build-app.sh installs there) or `open mac/MiniEreader.xcodeproj` and tell the user to press ⌘R.
5. **Before the Settings sheet appears, prompt the user to gather** (do NOT ask them to paste these into chat — they'll enter them directly into the app's Settings sheet, which writes to Keychain):
   - Instapaper consumer key + secret (link in the table above).
   - Instapaper username + password.
   - Anthropic API key.
6. **Verify success.** Ask the user to confirm:
   - The 📖 menu bar icon is visible.
   - Clicking it shows a list view with **Refresh** and **Settings** controls.
   - After entering credentials and clicking **Refresh**, articles from their Instapaper queue start appearing.
7. **If something breaks**, send them to the [Troubleshooting](#troubleshooting) section above. Do not invent fixes — every common failure is documented there.

## Not implemented (roadmap)

- Linux / Windows (macOS-only for now — CoreWLAN + MenuBarExtra are Apple-specific).
- Multi-user / cloud state.
- Manual file drop (drag an EPUB in, sync it).
- PDF conversion.
- Auto-launch at login.

PRs welcome.

## License

MIT — see [LICENSE](LICENSE).
