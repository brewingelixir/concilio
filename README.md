# Concilio

<p align="center">
  <img src="https://raw.githubusercontent.com/brewingelixir/concilio/main/docs/assets/header.png" alt="Concilio — multi-model LLM councils" width="820">
</p>

**Run a panel of LLMs that deliberate, critique each other, and synthesize one answer — locally, on your machine.**

Concilio is the open-source companion app for [`council_ex`](https://github.com/brewingelixir/council_ex). Point it at any LLM provider, ask a question, and watch a few models argue it out and converge. Save the conversation, build your own councils, inspect every run.

Single user. Local first. SQLite by default (Postgres opt-in). Phoenix LiveView.

## What's a council?

A *council* is structured peer review among models: specialized **members** run **rounds** of analysis — seeing each other's work across rounds — and a **chairman** synthesizes the final answer. Not blind ensemble voting; a deliberate process you control (roles, rounds, visibility). The mechanics live in [`council_ex`](https://github.com/brewingelixir/council_ex); Concilio is the UI to build, run, and inspect them.

## What you get

- **Chat** — talk to any model in your working set, or summon a council mid-thread. Plain turns and council turns coexist in one conversation. Markdown-rendered, per-chat model picker, auto-titled.
- **Council library** — bundled static councils (Debate, Jury, WeightedPanel, MultiModelPanel, …), one-click prebuilt topology scaffolds (Specialist, Consensus, Tournament, PeerReview, Voting, …), plus a full builder for your own. Templates are versioned: every edit is a new immutable version, so old runs reproduce exactly.
- **Visual builder** — author rounds, members, roles, tools, output schemas, and sub-councils with a live diagram preview. No DSL required.
- **Run timeline & diagrams** — every run is persisted whole (event timeline, per-member output, metrics, errors). Two council diagrams (flow swim-lanes + per-round trellis), plus **replay** (re-broadcast saved events at original timing) and **re-run** from any run page.
- **Providers** — enable providers, paste keys (encrypted at rest, AES-256-GCM, key derived from `CONCILIO_SECRET`), curate a working set of models, ping-test each one. OpenAI, Anthropic, Gemini, OpenRouter, Ollama.
- **Native menu-bar app** — macOS / Linux / Windows. No dock icon, no embedded WebView; the BEAM runs in the background, your default browser is the UI. Tray menu: Open / Settings / Dashboard / Reset Auth Token / Quit.
- **Background jobs** — Oban handles auto-titling, OpenRouter catalog refresh, run-event cleanup.

## Screenshots

<table>
  <tr>
    <td width="50%">
      <a href="https://raw.githubusercontent.com/brewingelixir/concilio/main/docs/assets/chat.png">
        <img src="https://raw.githubusercontent.com/brewingelixir/concilio/main/docs/assets/chat.png" alt="Chat with any model" width="100%">
      </a>
      <p align="center"><sub><b>Chat</b> — talk to any model in your working set</sub></p>
    </td>
    <td width="50%">
      <a href="https://raw.githubusercontent.com/brewingelixir/concilio/main/docs/assets/summon-council.png">
        <img src="https://raw.githubusercontent.com/brewingelixir/concilio/main/docs/assets/summon-council.png" alt="Summon a council mid-thread" width="100%">
      </a>
      <p align="center"><sub><b>Summon a council</b> mid-thread — template + question</sub></p>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <a href="https://raw.githubusercontent.com/brewingelixir/concilio/main/docs/assets/council-reply.png">
        <img src="https://raw.githubusercontent.com/brewingelixir/concilio/main/docs/assets/council-reply.png" alt="Council deliberates and synthesizes" width="100%">
      </a>
      <p align="center"><sub><b>Council reply</b> — members deliberate, chair synthesizes</sub></p>
    </td>
    <td width="50%">
      <a href="https://raw.githubusercontent.com/brewingelixir/concilio/main/docs/assets/councils.png">
        <img src="https://raw.githubusercontent.com/brewingelixir/concilio/main/docs/assets/councils.png" alt="Council library" width="100%">
      </a>
      <p align="center"><sub><b>Council library</b> — static, prebuilt, and dynamic</sub></p>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <a href="https://raw.githubusercontent.com/brewingelixir/concilio/main/docs/assets/run-timeline.png">
        <img src="https://raw.githubusercontent.com/brewingelixir/concilio/main/docs/assets/run-timeline.png" alt="Run timeline" width="100%">
      </a>
      <p align="center"><sub><b>Run timeline</b> — every run persisted, with replay + re-run</sub></p>
    </td>
    <td width="50%"></td>
  </tr>
</table>

## Status

`v0.1.0` — initial release. Single-user local tool. Multi-user / hosted deployment is out of scope.

## Quick start

### Install the desktop app

Download a prebuilt installer from the
[Releases page](https://github.com/brewingelixir/concilio/releases) — pick
the file for your platform:

| Platform | File |
|---|---|
| macOS (Apple Silicon) | `Concilio_*_aarch64.dmg` |
| Linux (x86_64) | `concilio_*_amd64.AppImage` or `.deb` |

> Only Apple-Silicon macOS and x86_64 Linux are built today. macOS
> (Intel), Linux (ARM64), and Windows are not yet published — build
> them from source (see below) or open an issue if you need a
> prebuilt binary.

On macOS, open the `.dmg` and drag `Concilio.app` into
`Applications`. The app is **unsigned**, so on first launch
Gatekeeper blocks it — and on Apple Silicon it shows the misleading
message *"Concilio is damaged and can't be opened. You should move
it to the Trash."* It is not damaged; macOS quarantines unsigned
apps downloaded from the internet. Clear the quarantine flag
(recursive — covers the bundled runtime inside the app):

```bash
xattr -dr com.apple.quarantine /Applications/Concilio.app
```

Then double-click to launch. (Right-click → **Open** does *not*
work for the "damaged" case — use the `xattr` command.)

What you get on launch:

1. Concilio runs in the **menu bar** (no dock icon, no app-switcher
   entry).
2. Your default browser opens to `http://localhost:<port>` with the
   auth token already injected — no copy-paste.
3. The menu bar icon's menu has **Open Concilio**, **Settings**,
   **Dashboard**, **Reset Auth Token**, and **Quit Concilio**.
4. Closing the browser tab leaves the app running; the menu bar
   icon stays put. Pick **Quit** (⌘Q) to fully shut down.

The app stores its data under `~/.concilio/`:
`concilio.db` (SQLite + WAL), `secrets/`, and `auth_token`. Back up
that directory to back up Concilio.

### Run from source

For development, or for users who'd rather not run a binary:

```sh
git clone https://github.com/brewingelixir/concilio.git
cd concilio
./scripts/dev server          # runs `mix phx.server` in app mode
```

Open <http://localhost:4000>. The first boot prints an auth token to
stdout and writes it to **`priv/.dev/auth_token`** (file 0600, dir
0700). Paste it on the login page.

`./scripts/dev help` lists every wrapper command (build, app, test,
release, release-app, precommit, clean, doctor).

#### Why dev uses a different `auth_token` path

Each environment has its own database, and the auth token's hash is
stored per-database. To prevent dev and prod from clobbering each
other's tokens via a shared file, the data dir defaults to a
different path per env:

| Env | Default data dir | DB path |
|---|---|---|
| Dev (`mix phx.server`) | `priv/.dev/` | `priv/repo/concilio_dev.db` |
| Test (`mix test`) | `$TMPDIR/concilio_test_<partition>/` | `priv/repo/concilio_test.db` |
| Prod (.app or `mix release`) | `~/.concilio/` | `~/.concilio/concilio.db` |

Override any of them with `CONCILIO_DATA_DIR=/some/path`. The
bootstrapper also self-heals: if the file's token doesn't match the
DB's hash on boot (e.g. you backed up the DB without the file), it
regenerates and prints a fresh token.

### Storage backend

Concilio defaults to **SQLite** (`ecto_sqlite3`). The DB file lives at
`$CONCILIO_DATA_DIR/concilio.db` (defaults vary per env — see the
table above). WAL mode is on; the `.db`, `.db-wal`, and `.db-shm`
files must travel together for any backup. No install required
beyond Concilio itself.

To use **Postgres** instead, recompile with the `CONCILIO_DB`
environment variable set:

```sh
mix do clean, deps.compile, compile
CONCILIO_DB=postgres MIX_ENV=prod mix release
```

The choice is compile-time (data layouts differ; flipping at runtime
isn't supported). Postgres deploys provide `DATABASE_URL`.

### Env vars

| Var | Required | Notes |
|---|---|---|
| `CONCILIO_DB` | optional | `sqlite` (default) or `postgres`. Compile-time only. |
| `CONCILIO_DATA_DIR` | optional | Per-install data dir (default differs per env: prod `~/.concilio`, dev `priv/.dev`, test `$TMPDIR/concilio_test_*`). Holds `concilio.db`, `auth_token`, `secrets/`. Override for tests, multiple instances, or relocating. |
| `CONCILIO_SECRET` | optional in prod | Derives the encryption key for stored provider credentials. Auto-generated to `~/.concilio/secrets/concilio_secret` (mode 0600) on first launch when absent. |
| `SECRET_KEY_BASE` | optional in prod | Signs cookies and LV tokens. Auto-generated to `~/.concilio/secrets/secret_key_base` on first launch when absent. |
| `DATABASE_URL` | prod, Postgres only | `ecto://USER:PASS@HOST/DATABASE`. Required when compiled with `CONCILIO_DB=postgres`. |
| `POOL_SIZE` | optional | Repo pool size. SQLite default `1` (single-writer); Postgres default `10`. |
| `OPENROUTER_API_KEY` | optional | First-run hint for the OpenRouter row in Settings. The credential of record is always the encrypted DB row. |
| `CONCILIO_NO_AUTH` | dev only | Set to `true` to bypass token auth in development. |
| `PORT` | optional | HTTP port (default 4000). |
| `PHX_BIND` | optional | `loopback` (default) or `all`. |
| `PHX_HOST` | optional | Hostname used in generated URLs (default `localhost`). |
| `PHX_SERVER` | optional | Set to `false` to skip starting the endpoint. |

### Reset the auth token

Three ways to rotate the token + session secret (kicks every active
cookie):

- **From the desktop app** — menu bar icon → **Reset Auth Token**.
  The new token is copied to your clipboard; reopen Concilio from
  the same menu and paste if the URL doesn't already include it.
- **From a deployed binary** (no `mix` available) — run
  `bin/app eval "IO.puts(Concilio.Release.reset_token())"`. Prints
  the new token; same DB updates as the tray menu.
- **From source / dev** —
  `./scripts/dev test :: mix concilio.reset_token --yes`
  (or any of the other `mix concilio.reset_token` invocations).

## First-time configuration

1. Sign in at `/login` with the printed token.
2. Go to **Settings → Providers**, enable a provider, paste an API key. Click "Test" on a few models to verify connectivity.
3. Visit **Councils**, pick the bundled `Demo` template, click **Run now**, type a question. Watch the timeline at `/runs/:id`.
4. Try **+ Summon council** in a conversation to weave council turns into a normal chat thread.

## Releases

### SQLite (default — single binary, no DB install)

```sh
MIX_ENV=prod mix release concilio
_build/prod/rel/concilio/bin/concilio start
```

On first launch the release creates `~/.concilio/`, generates
`~/.concilio/secrets/{concilio_secret,secret_key_base}` (mode 0600),
runs migrations, and serves on `http://localhost:4000`. No env vars
required to boot.

### Postgres (opt-in for hosted deploys)

```sh
CONCILIO_DB=postgres MIX_ENV=prod mix release concilio
DATABASE_URL=ecto://user:pass@host/db \
  CONCILIO_SECRET=$(openssl rand -base64 48) \
  SECRET_KEY_BASE=$(mix phx.gen.secret) \
  _build/prod/rel/concilio/bin/concilio start
```

### Desktop app (Tauri — macOS / Linux / Windows)

```sh
./scripts/dev build
```

Produces `rel/app/src-tauri/target/release/bundle/macos/Concilio.app`
on macOS. The app runs tray-only: spawns the BEAM on a dynamic
loopback port, opens your default browser auto-authenticated, and
sits in the menu bar. Closing the browser tab leaves Concilio
running; **Quit** in the tray menu (or ⌘Q) tears down the BEAM.

Local builds skip the `.dmg` / `.AppImage` / `.exe` packaging
because those steps need permissions the CI runners get for free
but a freshly-installed dev box doesn't (macOS Finder AppleScript
permission, etc). Set `CONCILIO_BUNDLE_ALL=1` to opt in. CI
(`.github/workflows/release.yml`) sets it for the full matrix on
tag push.

See [`docs/RELEASE.md`](docs/RELEASE.md) for the full pipeline:
prerequisites (Rust + cargo + tauri-cli + Node + xz), how the
`mix release app` step is bundled into the Tauri payload, and the
GitHub Actions matrix.

## Docs

- `docs/ARCHITECTURE.md` — layered overview, supervision tree, schemas.
- `docs/RELEASE.md` — Tauri build + GitHub Actions release pipeline.
- `docs/UPDATING_PROVIDER_CATALOG.md` — how the provider/model catalog is maintained.
- `docs/CONCILIO_VISUALIZATION_RESEARCH.md` — research notes on run/council visualization (future work).
- `docs/CONCILIO_OPEN_QUESTIONS.md` — running log of open questions and known gaps.
- `AGENTS.md`, `CLAUDE.md` — repo conventions for AI assistants.
- `CHANGELOG.md` — release history.
- `CONTRIBUTING.md` — dev setup and workflow.

## License

Apache License 2.0. See [`LICENSE`](LICENSE). Matches [`council_ex`](https://github.com/brewingelixir/council_ex).
