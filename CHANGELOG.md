# Changelog

All notable changes to Concilio are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project follows
[Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [0.1.0] - 2026-05-31

First public release. Concilio is a single-user, local-first Phoenix
LiveView companion app for [`council_ex`](https://github.com/brewingelixir/council_ex):
build and run multi-model LLM councils (deliberation → peer review →
chairman synthesis), inspect and replay run timelines, and chat with
any model in your working set.

### Chat

- Chat with any model in your working set at `/` and `/c/:id`, with a
  sidebar of conversations and auto-titling.
- **Summon a council mid-conversation** — plain turns and council turns
  coexist in the same thread, with live updates streamed over PubSub.
- Reference a past council result in a later message with a
  `[council:<id>]` token, expanded server-side into the chair's
  synthesis at send time.
- Assistant output renders as Markdown (GFM tables, fenced code, hard
  breaks).

### Councils

- **Bundled static councils** auto-discovered from `Concilio.Councils.*`
  (debate, critique, jury, peer review, panels, and more).
- **Prebuilt topology scaffolds** (Specialist, Consensus, Tournament,
  WeightedConsensus, JuryWithRetry, ParallelPanel, PeerReview, Voting)
  surfaced as one-click "seed a new dynamic council" cards.
- **Dynamic builder** for your own councils — member rows, chairman,
  per-member working-set pickers. Templates are versioned: editing
  creates a new immutable version row, so historical runs reproduce
  against the spec they actually ran under. Clone any template to a
  dynamic one.

### Runs

- Every council run is persisted in full: hierarchical event timeline,
  per-member output, metrics (wall time, tokens, cost, errors), and a
  per-event detail pane.
- **Replay** re-broadcasts saved events with their original timing;
  **re-run** links back to the parent via `parent_run_id`. Cancel
  in-flight runs from the run detail page.

### Providers

- Enable/disable providers and manage API keys, **encrypted at rest**
  with AES-256-GCM (key derived from `CONCILIO_SECRET`).
- Curate a per-provider working set of models; test each model with a
  real one-shot ping that surfaces status, latency, and the full error
  on failure.
- Status badges reflect real working state
  (**setup needed → select model → run model test → working**), not a
  raw enabled flag.
- Hand-curated provider catalog reconciled on boot; locally-pulled
  Ollama models surface alongside the bundled list.

### Auth

- Token-based auth: a 32-byte token generated on first launch, hashed
  at rest, with an ETS rate limiter on login and a rotating session
  secret that invalidates every cookie on logout.
- Reset the token from the desktop tray, a deployed binary
  (`bin/app eval`), or `mix concilio.reset_token`.

### Storage & distribution

- **SQLite by default** (`ecto_sqlite3`, WAL mode) — no external
  database to install. **Postgres opt-in** via the compile-time
  `CONCILIO_DB=postgres` switch. Oban engine matches the backend.
- **Tray-only Tauri desktop app** for macOS / Linux / Windows: no dock
  icon, no embedded WebView. The BEAM runs in the background and your
  default browser is the UI, auto-authenticated via an injected token.
  Tray menu: Open / Settings / Dashboard / Reset Auth Token / Quit.
- Per-environment data dirs (dev / test / prod isolated) with a
  self-healing auth bootstrapper, and first-launch secret generation so
  the app boots with zero environment configuration.
- Background jobs (Oban) for conversation auto-titling, provider
  catalog refresh, and run-event cleanup.
- GitHub Actions release pipeline builds `.dmg` / `.AppImage` / `.deb` /
  `.exe` with `SHA256SUMS` on `v*` tag push.

[0.1.0]: https://github.com/brewingelixir/concilio/releases/tag/v0.1.0
