# Harness for Mac

An **unofficial** native macOS app for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`).

It runs the harness's own web UI inside a native window, so the interface is exactly the
official one — same code, same features, same updates — while the app gives it what a browser
tab cannot: a Dock icon, a real menu bar, window state that survives relaunches, and a `dsh`
server whose whole lifecycle is owned by the app.

> Not affiliated with or endorsed by DeepSeek. "DeepSeek" and "DeepSeek Harness" are
> trademarks of their respective owners.

## What it does

- Starts `dsh --profile web --no-open` bound to `127.0.0.1` and loads it in a `WKWebView`.
- Stops it on quit (SIGTERM, then SIGKILL after 6 s so MCP servers are shut down cleanly).
  If the app is killed, the stdin pipe closes and `dsh` exits on its own.
- Keeps the server on loopback: any other link opens in your default browser.
- Uses a stable local port (3179, falling back to a free one) so the UI's local storage —
  current session, drafts — survives relaunches.
- Native menus: ⌘R reload, ⇧⌘R restart the harness, ⇧⌘O open in browser, ⌘0/⌘=/⌘- zoom,
  full screen, standard Edit shortcuts.
- Nothing leaves your Mac: the app reads no credentials and sends no telemetry. Your harness
  settings, keys and sessions stay where `dsh` keeps them (`~/.dsh`).

## Requirements

- macOS 15 or later (Apple silicon or Intel).
- DeepSeek Harness installed and on your `PATH` — follow the
  [official quickstart](https://deepseek-harness.github.io/deepseek-harness/en/guide/quickstart).
  The app resolves `PATH` from your login shell, so if `dsh` works in Terminal it works here.
  To point at a specific binary:
  `defaults write io.github.harness-mac dshPath /path/to/dsh`

## Build

```sh
swift test                 # unit tests
scripts/bundle.sh          # universal, ad-hoc signed dist/Harness.app
open dist/Harness.app
```

The first launch of an ad-hoc signed app needs right-click → Open.

## Headless check

The app can render off-screen, save a PNG and exit — handy for CI and for verifying a change
without taking over your screen:

```sh
HARNESS_SNAPSHOT=/tmp/harness.png dist/Harness.app/Contents/MacOS/Harness
```

`HARNESS_SNAPSHOT_JS` is evaluated in the page after it loads, and `HARNESS_SNAPSHOT_DELAY`
(seconds, default 5) is waited before and after it.

## Layout

| Path | What |
|---|---|
| `Sources/HarnessApp` | AppKit app: window, menus, `WKWebView` host |
| `Sources/DSHKit` | Typed Swift client for `dsh`: web server lifecycle and the SDK stdio JSON-RPC protocol |
| `Sources/harness-smoke` | CLI that drives the SDK runtime end to end (`harness-smoke <provider> <model> "<prompt>"`) |
| `Tests/DSHKitTests` | Framing, protocol decoding, settings, transcript reducer, URL parsing |

## Notes

- Startup time is whatever `dsh` needs: with many MCP servers configured it can take close to a
  minute. The app waits up to 180 s.
- SDK sessions (`DSHKit`) cannot be resumed across runtime processes; that limit comes from `dsh`.

## License

MIT
