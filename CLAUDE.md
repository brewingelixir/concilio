# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project context

Concilio is a single-user, locally-run Phoenix LiveView companion app for [`council_ex`](https://github.com/brewingelixir/council_ex). It builds, runs, and inspects multi-model LLM councils (deliberation + peer review + chairman synthesis), persists run timelines, and supports a chat MVP. Open-source release target.

**Repo conventions and the operating contract live in `AGENTS.md`. Read it before non-trivial work.** `docs/ARCHITECTURE.md` is the reference for what is built, why, and where to find it.

The app is fully built: chat (plain + council turns), static/prebuilt/dynamic councils, a full dynamic builder, run timeline + replay + re-run, provider settings with encrypted keys, token auth, Oban jobs, and a tray-only Tauri desktop app. `mix precommit` is the gate before declaring work done.

## Commands

```bash
mix setup              # deps + ecto.create + ecto.migrate + seeds + assets
mix phx.server         # run server on :4000  (or `iex -S mix phx.server`)
mix test               # auto-creates+migrates the test DB, then runs tests
mix test path/to/file_test.exs[:LINE]   # single file / single test
mix test --failed      # rerun only previously failed
mix precommit          # compile --warnings-as-errors + deps.unlock --unused + format + test
mix ecto.reset         # drop + recreate + migrate + seed
mix ecto.gen.migration name_using_underscores  # always use this (never hand-name files)
mix help <task>        # read before invoking unfamiliar mix tasks
```

`mix precommit` is the gate before declaring work done. Run it.

`./scripts/dev <cmd>` wraps the dev/release workflow (`server`, `build`, `app`, `test`, `release`, `release-app`, `precommit`, `clean`, `doctor`) and sets app-mode env (`CONCILIO_APP=1`) for desktop builds — `./scripts/dev help` lists all. Use it for anything touching the Tauri/desktop path; raw `mix` is fine for pure backend work.

## Architecture

Standard Phoenix 1.8 / LiveView 1.1 layout. Two top-level namespaces:

- `Concilio.*` — domain (`Concilio.Repo`, contexts, Oban workers).
- `ConcilioWeb.*` — web layer; `lib/concilio_web.ex` defines the `:controller`, `:live_view`, `:html`, `:router` macros and aliases `ConcilioWeb.Layouts` for all HTML modules.

Supervision tree (`lib/concilio/application.ex`): `Telemetry → Repo → DNSCluster → Phoenix.PubSub (Concilio.PubSub) → Endpoint`. **Do not add `council_ex` modules to this tree** — `CouncilEx.Application` starts its own runner supervisor. `council_ex` is configured to use `Concilio.PubSub` via `{CouncilEx.PubSub.Phoenix, name: Concilio.PubSub}`.

### Domain model

- `council_template` (static module *or* dynamic DB row) → `council_template_versions` (immutable; runs pin to a version) → `runs` (one execution; persisted event timeline) → `run_events` (replay source).
- **Prebuilt scaffolds** (`Concilio.Councils.Prebuilt`, pure data — no DB row): curated `CouncilEx.Councils.*` topology generators surfaced on `/councils` with the `prebuilt` badge. Click → `/councils/new?prebuilt=<slug>` → builder seeds rounds + chair + N empty members → save produces a normal `:dynamic` row. Always visible (the "Show examples" toggle only gates `:static`).
- `conversations` → `messages`; each assistant message links to one `runs` row.
- `provider_settings` holds encrypted API keys (key derived from `CONCILIO_SECRET`); `app_state` single-row holds the auth token hash + rotating session secret. Auth is token-based (not a PIN); storage is **SQLite by default with Postgres opt-in**; styling is Tailwind + DaisyUI.

### Stack quick-reference (post 2026-05-08 swap)

- DB is **SQLite via `:ecto_sqlite3`** by default. Postgres opt-in via `CONCILIO_DB=postgres` at compile time. `lib/concilio/repo.ex` baked the adapter at compile time; switching = `mix do clean, deps.compile, compile`. Both deps ship in `mix.exs`.
- Dev DB: `priv/repo/concilio_dev.db`. Test DB: `priv/repo/concilio_test*.db`. Prod DB (SQLite path): `$CONCILIO_DATA_DIR/concilio.db` (default `~/.concilio/concilio.db`). All gitignored.
- WAL mode mandatory (`journal_mode: :wal` set in every config). Sidecars `concilio.db-wal` + `concilio.db-shm` must travel with the main file for any backup.
- `pool_size: 1` everywhere on the SQLite path. `busy_timeout: 30_000`. **Do not raise the pool** — SQLite is single-writer, the Sandbox handles test isolation via transaction rollback rather than separate connections.
- Oban engine: `Oban.Engines.Lite` (SQLite) or `Oban.Engines.Basic` (Postgres). `config/config.exs` branches on `CONCILIO_DB`.
- Migrations: SQLite does not support `ALTER TABLE ADD CONSTRAINT` or `ALTER COLUMN`. Inline checks and FKs in the original `create table` block; do not retroactively `alter table` an existing column. The two existing exceptions (`app_state` singleton CHECK, `council_templates.current_version_id` FK) are documented in their migration files.
- Auto-migrate: in `:prod` only, `Concilio.Application.maybe_auto_migrate/0` runs `Concilio.Release.migrate/0` before the endpoint comes up. On failure the error is logged + stashed in `Application.put_env(:concilio, :migration_error, ...)`; the app boots but most queries fail until resolved.
- Persisted secrets: `runtime.exs` reads / creates `$DATA_DIR/secrets/concilio_secret` and `$DATA_DIR/secrets/secret_key_base` (mode 0600) on first launch. Env vars (`CONCILIO_SECRET`, `SECRET_KEY_BASE`) override the files.
- **Per-env data dir**: dev → `priv/.dev/`, test → `$TMPDIR/concilio_test_*/`, prod → `~/.concilio/`. `CONCILIO_DATA_DIR` overrides any of them. `runtime.exs` always publishes the resolved dir as `Application.get_env(:concilio, :data_dir)`. `Concilio.Auth.TokenStore` resolves through that, then env, then home. **Don't hardcode `~/.concilio/...`** — read `:data_dir`. The bootstrapper self-heals if the on-disk token doesn't `Token.verify` against `app_state.token_hash` (file/hash drift = regenerate).
- **Desktop distribution = Tauri tray-only** (`rel/app/`). No embedded WebView. Rust shell spawns the BEAM, waits on `GET /health`, opens the user's default browser at `?token=<...>` (auth pipeline consumes the query, sets session cookie, redirects to clean URL). `LSUIElement = true` → no dock icon. Tray menu: Open / Settings / Dashboard / Reset Auth Token / Quit. Reset Auth Token uses `bin/app rpc` (against the running BEAM, no second VM) + clipboard + native notification. BEAM child has a `Drop` impl in Rust so any exit path SIGTERMs cleanly. See `docs/RELEASE.md`.
- **App-mode flag**: `CONCILIO_APP=1` at compile time exposes `/dev/dashboard` (LiveDashboard) and sets `check_origin: false` in prod (the Tauri shell hits loopback `127.0.0.1:<dyn-port>`, which fails Phoenix's default origin check otherwise). Tauri build always sets it; vanilla server compiles don't.
- **Local desktop build**: `./scripts/dev build` produces `Concilio.app`. macOS DMG packaging is gated behind `CONCILIO_BUNDLE_ALL=1` because `bundle_dmg.sh` needs Finder AppleScript permission that fresh dev boxes don't have. CI sets the flag to opt in.
- **Provider catalog**: `lib/concilio/providers/catalog.ex` is hand-curated per provider, reconciled into `provider_models` on boot (new rows inserted, missing rows stamped `deprecated_at`). Update procedure + source URLs in `docs/UPDATING_PROVIDER_CATALOG.md`. Locally-pulled Ollama models the user has installed surface alongside the bundled list via `source: :local_detected`.
- **Provider status badge** (`/settings/providers`): driven by working state, not raw `enabled` flag. Sequence: `setup needed` → `select model` → `run model test` → `working`. Predicate is `Providers.working?/1` and `Providers.working?/2`. The X icon on each card calls `Providers.remove/1` (deletes the setting + every model row); working providers get a `data-confirm` prompt.

### Hard rules (most likely to bite during day-to-day work)

1. **Don't fork or modify `council_ex`.** Consume as `{:council_ex, "~> 0.1"}`. Surface gaps in `docs/CONCILIO_OPEN_QUESTIONS.md`; don't reach into private state.
2. **One Repo, one Oban instance** — both come from the Phoenix scaffold. Don't start a second.
3. **Run lifecycle goes through `Concilio.RunRecorder` (GenServer).** Its `init/1` calls `CouncilEx.start_supervised_run/3` with `subscribe: true` + `supervisor: Concilio.RunSupervisor` + `relay_topics: ["concilio:runs"]`. The `subscribe: true` flag installs the per-run subscription on the recorder process before the RunServer spawns — never call `start_run` directly from a LV/controller and subscribe afterwards (race drops `:run_started`). `ConcilioWeb.RunStarter.start/3` is the only sanctioned entry point.
4. **Don't block LiveView on synchronous `CouncilEx.run/3`** — councils are multi-second. Use the async pattern from `council_ex/docs/RUNNING_IN_PHOENIX.md` §3.
5. **Reuse `"council_ex:run:#{run_id}"` PubSub topics** and the tuple shapes from `CouncilEx.Events` byte-for-byte. The recorder and timeline depend on it.
6. **Persist as JSON** via explicit `to_map/1` + `from_map/1` per struct, with a `payload_version` smallint. Never `:erlang.term_to_binary` into a column.
7. **Dynamic templates are immutable per version** — every save creates a new `council_template_versions` row so old runs reproduce against their pinned version. Archive (`archived_at`) instead of deleting referenced templates.
8. **Provider keys never live in `config/runtime.exs`** — encrypted in `provider_settings` rows.
9. **Dynamic-council `spec_json` shape**: rounds are `[%{"type" => name, "opts" => map}]` (post 2026-05-06 builder-parity work), not bare strings. Members carry `role`, `temperature`, `max_tokens`, `tools`, `output_schema` / `output_schema_inline`, `sub_council`, `input_mapper`. Council carries `default_profile`, `router`, `tools`, `metadata`. `RunStarter.dynamic_member_attrs/1` lifts numerics into `profile_overrides` at hydration.

## Conventions specific to this codebase (from AGENTS.md)

`AGENTS.md` is the canonical Phoenix 1.8 / LiveView 1.1 / HEEx / Ecto / test guide for this repo. Read it. The points most likely to trip you up:

- LiveView templates **must** start with `<Layouts.app flash={@flash} ...>`. `<.flash_group>` only lives inside `layouts.ex`.
- Use the imported `<.icon name="hero-…" />` and `<.input>` from `core_components.ex`. Never `Heroicons` modules. Never `Phoenix.HTML.form_for`.
- Forms: `to_form/2` in the LV → `<.form for={@form} id="...">` in the template → `@form[:field]` access. **Never** pass a changeset to `<.form>`.
- LiveView streams for any collection. `phx-update="stream"` + DOM id on parent + per-item id. Streams aren't enumerable; refilter by re-streaming with `reset: true`.
- `<.link navigate={...}>` / `<.link patch={...}>` and `push_navigate` / `push_patch`. `live_redirect`/`live_patch` are deprecated.
- HEEx: `{...}` in attrs and tag bodies; `<%= %>` only inside tag bodies for block constructs (`if`/`for`/`case`/`cond`). No `else if`/`elseif` — use `cond`. Multi-class is list syntax `class={[...]}`.
- Avoid `LiveComponent` unless there's a strong need.
- HTTP client: `:req` (already present transitively). Never add `:httpoison`/`:tesla`/`:httpc`.
- Tests: `start_supervised!/1`, never `Process.sleep/1`/`alive?/1`. Sync via `Process.monitor` + `assert_receive {:DOWN,...}` or `:sys.get_state/1`. Test against element IDs (`has_element?/element/2`), not raw HTML or text.
- Ecto: preload anything templates touch; programmatically-set fields (e.g. `user_id`) never go in `cast/3`; access changeset fields via `Ecto.Changeset.get_field/2`.
- Elixir: lists don't support `mylist[i]` (use `Enum.at`); rebind block results (`socket = if ... do assign(...) end`); never nest modules in one file; never `String.to_atom/1` user input; predicate names end in `?`, not `is_`; `Task.async_stream` with `timeout: :infinity` for concurrent enumeration.

## .env handling

`.env` files are **never read** in this repo (global rule). Use `.env.example` for the canonical key list and `config/runtime.exs` for what the app expects. When unsure if a value is set, ask the human.
