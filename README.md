# DSH for Mac

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
  `dsh --profile web` does not exit when its parent dies, so the app records the server's pid and
  stops a leftover server on the next launch (after a crash or force quit).
- Starts a fresh server on each launch and loads the login URL it emits. A response from `/`
  without that login token does not establish an authenticated session.
- Starts `dsh` at user-initiated QoS. **View → Keep Mac Awake While DSH Runs** is on by
  default to prevent idle sleep during a task and can be turned off.
- Keeps the server on loopback: any other link opens in your default browser.
- Uses a stable local port (3179, falling back to a free one) so the UI's local storage —
  current session, drafts — survives relaunches.
- Native menus: ⌘R reload, ⇧⌘R restart the harness, ⇧⌘O open in browser, ⌘0/⌘=/⌘- zoom,
  full screen, standard Edit shortcuts.
- Blends the native titlebar into the harness canvas while keeping macOS window controls.
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
scripts/bundle.sh            # universal, ad-hoc signed dist/DSH.app
scripts/bundle.sh --install  # same, replacing /Applications/DSH.app (one copy only)
```

The first launch of an ad-hoc signed app needs right-click → Open.

The app icon is the harness's own logo, read at build time from your local `dsh` installation
(it is not part of this repository). Without `dsh` installed, a neutral icon is used.

## Headless check

The app can render off-screen, save a PNG and exit — handy for CI and for verifying a change
without taking over your screen:

```sh
HARNESS_SNAPSHOT=/tmp/harness.png /Applications/DSH.app/Contents/MacOS/DSH
```

`HARNESS_SNAPSHOT_JS` is evaluated in the page after it loads, and `HARNESS_SNAPSHOT_DELAY`
(seconds, default 5) is waited before and after it.

## Layout

| Path | What |
|---|---|
| `Sources/HarnessApp` | AppKit app: window, menus, `WKWebView` host |
| `Sources/DSHKit` | Typed Swift client for `dsh`: web server lifecycle and the SDK stdio JSON-RPC protocol |
| `Sources/harness-smoke` | CLI that drives the SDK runtime end to end (`harness-smoke <provider> <model> "<prompt>"`) |
| `Sources/webserver-smoke` | CLI that starts and stops `dsh --profile web` N times and prints boot times (`webserver-smoke 6`) |
| `Tests/DSHKitTests` | Framing, protocol decoding, settings, transcript reducer, URL parsing |

`webserver-smoke` uses an OS-assigned port, checks that the emitted login URL authenticates,
and checks that the server stops accepting connections after `stop()`.

`python3 scripts/reconnect-smoke.py` runs the app off-screen with a temporary DSH profile,
terminates only its own server child, checks that the page reconnects, and verifies the
replacement server exits with the app.

For a minimal SDK request with a selected effort, set `HARNESS_SMOKE_EFFORT` before running
`harness-smoke`. The effort must be declared for that model by the installed DSH configuration.
Set `HARNESS_SMOKE_EXPECT` to require an exact synthetic answer; without it, the smoke check
can only tell that an assistant message arrived, not that the route actually succeeded.

## Notes

See [the integration contract](docs/INTEGRATIONS.md) for model, effort, OAuth, agent, MCP,
and Jev boundaries.

- A healthy `dsh` boot took 3–8 s in local checks. An intermittent DSH boot produced no URL
  until the watchdog restarted it (35.8 s in an eight-run sample). The app now restarts once
  after 15 s without a URL and then waits up to 180 s for the retry. The underlying DSH stall
  remains under investigation.
- The model and effort menus are supplied by the installed DSH Web UI. Custom models show an
  Effort menu only when they declare `reasoningEfforts` in `$DSH_HOME/settings.yaml`. Leaving
  effort unselected lets the configured route choose automatically. The app does not create a
  separate model entry for each effort.
- SDK sessions (`DSHKit`) cannot be resumed across runtime processes; that limit comes from `dsh`.

## License

MIT
