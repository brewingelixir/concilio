# Release & distribution

Concilio ships in two shapes:

1. **Desktop app** — a Tauri-wrapped native installer (`.dmg`,
   `.AppImage`, `.deb`, `.exe`) that bundles the BEAM and runs
   tray-only on macOS / Linux / Windows: `LSUIElement = true`, no
   dock icon, no app-switcher entry, **no embedded WebView**. The
   Rust shell spawns the BEAM on a dynamic loopback port, waits on
   `GET /health`, and opens `http://127.0.0.1:<port>?token=<...>`
   in the user's default browser. The auth token comes from
   `<data-dir>/auth_token`; Phoenix's auth pipeline consumes it,
   stamps a session cookie, and redirects to a clean URL — so the
   user sees a logged-in session on first paint without
   copy-paste. Mirrors Livebook's pattern.
2. **Vanilla Erlang release** — `mix release concilio` produces
   a standard tarball at `_build/prod/rel/concilio/`. For Docker,
   Fly, Render, or any VPS deploy. Storage backend is selected at
   compile time via `CONCILIO_DB`.

## Vanilla release (Docker / Fly / Render / VPS)

### SQLite (default)

```sh
MIX_ENV=prod mix release concilio
_build/prod/rel/concilio/bin/concilio start
```

On first launch the release creates `~/.concilio/`, generates
`~/.concilio/secrets/{concilio_secret,secret_key_base}` (mode
0600), runs migrations, and serves on `http://localhost:4000`.
No env vars required to boot.

### Postgres

```sh
CONCILIO_DB=postgres MIX_ENV=prod mix release concilio
DATABASE_URL=ecto://user:pass@host/db \
  CONCILIO_SECRET=$(openssl rand -base64 48) \
  SECRET_KEY_BASE=$(mix phx.gen.secret) \
  _build/prod/rel/concilio/bin/concilio start
```

`CONCILIO_DB` is a **compile-time** switch. Flipping after the fact
requires `mix do clean, deps.compile, compile`. Storage backends
have different on-disk shapes; the codebase warns rather than
trying to migrate data.

## Desktop app (Tauri)

### Toolchain prerequisites (local builds)

You only need these for building the desktop app — `mix
phx.server`, `mix test`, and vanilla `mix release` do not require
them.

| Tool                            | Notes                                                                                            |
| ------------------------------- | ------------------------------------------------------------------------------------------------ |
| Erlang/OTP 27.x + Elixir 1.18.x | Same as dev.                                                                                     |
| Node 20+                        | For `mix assets.deploy` (Tailwind + esbuild).                                                    |
| Rust (stable) + cargo           | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` or `brew install rustup-init`. |
| `tauri-cli` (^2.0)              | `cargo install tauri-cli --version "^2.0" --locked`.                                             |
| Linux-only deps                 | `libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev libssl-dev patchelf` (apt).             |

Icons must be generated from a source SVG before the first build —
see `rel/app/src-tauri/icons/README.md`. The bundled icon set is
not committed.

### Local build

```sh
./scripts/dev build
```

(or `bash rel/app/tauri.sh build` directly — `scripts/dev` just
wraps it in `mise exec --` so the pinned Elixir / Rust / Zig / Node
versions are used).

Output paths (relative to `rel/app/src-tauri/target/release/bundle/`):

| Platform | Files                                                |
| -------- | ---------------------------------------------------- |
| macOS    | `macos/Concilio.app`                                 |
| Linux    | `appimage/concilio_*.AppImage`, `deb/concilio_*.deb` |
| Windows  | `nsis/Concilio_*-setup.exe`                          |

**Local builds default to `--bundles app` on macOS** because the
`bundle_dmg.sh` step needs AppleScript "control Finder" permission
that fresh dev boxes don't have. Set `CONCILIO_BUNDLE_ALL=1` to opt
in to the full bundle (`.dmg` / `.AppImage` / `.deb` / `.exe`); CI
sets it automatically. The `.app` itself is fully functional — drop
it into `/Applications` to install.

For a build-and-launch in one shot (macOS / Windows):

```sh
./scripts/dev app
```

`tauri.sh` exports `CONCILIO_APP=1` and `MIX_ENV=prod`, runs
`mix release app` into the per-OS resource directory, then invokes
`cargo tauri build`.

### Tray menu

Once installed, the app lives in the menu bar:

| Item             | Shortcut | What it does                                                                                                 |
| ---------------- | -------- | ------------------------------------------------------------------------------------------------------------ |
| Open Concilio    | ⌘⇧O      | Opens `/?token=<...>` in the default browser                                                                 |
| Settings         | ⌘,       | Opens `/settings`                                                                                            |
| Dashboard        | ⌘⇧D      | Opens `/dev/dashboard` (Phoenix LiveDashboard)                                                               |
| Reset Auth Token | —        | Rotates the token via `bin/app rpc`, copies the new one to the system clipboard, fires a native notification |
| Quit Concilio    | ⌘Q       | SIGTERMs the embedded BEAM and exits                                                                         |

The browser tab is the UI; the `.app` itself never opens a window.
Closing the browser tab leaves the BEAM running and the tray icon
alive — pick **Open Concilio** again to bring up a fresh tab.
**Quit** is the only path that tears down the BEAM. The Rust shell
holds the BEAM child in a `Mutex<Option<Child>>` whose `Drop` impl
SIGTERMs the process, so any path that ends the app — Quit menu,
NSApp `terminate:`, signal, panic — cleans up the BEAM. No orphans.

### macOS Gatekeeper

Local and CI builds are unsigned. macOS Gatekeeper refuses to
launch them on first run — on Apple Silicon it shows *"Concilio is
damaged and can't be opened"* (it isn't; that's the unsigned-app
quarantine). Strip the quarantine attribute **recursively** (the
non-recursive `xattr -d` leaves the flag on the bundled runtime
inside the `.app` and the "damaged" error persists):

```sh
xattr -dr com.apple.quarantine /Applications/Concilio.app
```

Right-click → Open does *not* clear the "damaged" state — use the
`xattr` command. Apple Developer signing + notarization is deferred
to a future release.

### Windows SmartScreen

Same story — unsigned binary triggers a SmartScreen warning. Click
**More info** → **Run anyway** the first time. EV signing deferred.

### Linux tray quirks

The system tray on Linux relies on `StatusNotifierItem`. GNOME
40+ needs the [AppIndicator extension] for the tray to appear at
all. KDE Plasma works out of the box. Without the extension the
app still spawns the BEAM and opens the browser at start, but the
menu bar entry won't show — meaning Open / Settings / Dashboard /
Reset Auth Token / Quit are unreachable. Quit then has to come
from `pkill concilio` or letting the AppImage process exit.

[AppIndicator extension]: https://extensions.gnome.org/extension/615/appindicator-support/

## CI release pipeline

Workflow file: `.github/workflows/release.yml`.

### Triggers

- **Tag push** (`v*`): full pipeline, builds all targets, attaches
  binaries + `SHA256SUMS` to the GitHub Release for that tag.
- **Manual dispatch** (`workflow_dispatch`): same matrix but skips
  the publish step. Artifacts land on the Actions run page.

### Cutting a release

```sh
git tag v0.1.0
git push origin v0.1.0
```

That kicks the workflow. Each matrix entry runs natively on its
target host (no NIF cross-compilation):

| Runner             | Target                      |
| ------------------ | --------------------------- |
| `macos-14`         | `aarch64-apple-darwin`      |
| `macos-13`         | `x86_64-apple-darwin`       |
| `ubuntu-22.04-arm` | `aarch64-unknown-linux-gnu` |
| `ubuntu-22.04`     | `x86_64-unknown-linux-gnu`  |
| `windows-2022`     | `x86_64-pc-windows-msvc`    |

The final `release` job downloads all artifacts, combines the
checksum files, and publishes the Release with auto-generated
notes.

## Auto-update

Not implemented. Users redownload on new releases. No background
update mechanism is planned for v1.

## Backup & restore

The data dir holds everything Concilio needs. To back up:

```sh
# Quit the app first so the WAL is checkpointed.
cp -r ~/.concilio ~/concilio-backup-$(date +%Y%m%d)
```

The `.db`, `.db-wal`, and `.db-shm` files must travel together. The
Settings UI exposes a one-click backup that does the safe checkpoint

- copy.

To restore: quit the app, replace `~/.concilio`, relaunch.
