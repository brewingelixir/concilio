# Concilio architecture reference

Single source of truth for **what is built**, **why**, and **where to
find it**. For repo conventions and the operating contract, see
`AGENTS.md` and `CLAUDE.md`.

When the design or scope changes, update **this** file too.

---

## 1. Domain model

```
council_templates ──< council_template_versions ──< runs ──< run_events
       │                                              │
       └─────────────── current_version_id ───────────┘
                                                      │
                                                      ▼
                                              messages.run_id
                                                      │
conversations ──< messages                            │
       │             │                                │
       └────── default_template_id (optional) ◄───────┘

provider_settings (1 row per provider, encrypted creds)
provider_models   (1 row per (provider, model_id), curated working set)

app_state         (single row: token_hash, rotating session secret, kv)
```

### Entities + invariants

- **`council_templates`** — A reusable spec.
  - `kind: :static | :dynamic`. Static = backed by an Elixir module
    discovered under `Concilio.Councils.*`. Dynamic = authored via
    the builder UI.
  - **Prebuilt scaffolds** are a third surface, _not_ a DB row.
    Curated `CouncilEx.Councils.*` topology generators (Specialist,
    Consensus, Tournament, WeightedConsensus, JuryWithRetry,
    ParallelPanel, PeerReview, Voting) live in
    `Concilio.Councils.Prebuilt` as plain data — name, description,
    rounds, suggested-member count, chair prompt. The `/councils`
    index renders them with a `prebuilt` badge alongside DB
    templates; clicking one navigates to
    `/councils/new?prebuilt=<slug>` and the builder seeds rounds +
    chair stub + N empty member slots. Saving produces a normal
    `:dynamic` row — the prebuilt is just a starting point, never
    persisted as its own kind. Visible regardless of the "Show
    examples" toggle (the toggle only gates `:static`).
  - `current_version_id` always points at the latest
    `council_template_versions` row.
  - `cloned_from_template_id` + `cloned_from_version_id` track
    provenance for clone-to-dynamic.
  - `archived_at` soft-archives. Templates referenced by runs are
    never hard-deleted.
  - `samples` — JSON array of `%{"title", "input", "context"?}` entries.
    Static-only: bundled modules opt in via a `samples/0` callback;
    `Concilio.Councils.upsert_static_template!/1` normalizes (trims
    blanks, drops empty inputs) and writes the list on every sync, so
    samples drift with the module like spec_json does. Dynamic
    templates always carry `[]` — the "Random example input" button
    on the Run-now modal is gated on `kind == :static and samples != []`,
    so cloning a static template into a dynamic one drops the
    affordance automatically.
- **`council_template_versions`** — Immutable spec snapshots.
  - Editing a dynamic template inserts a _new_ version row;
    historical runs stay pinned to the version they ran under so
    replay reproduces faithfully.
  - **Static templates** also get the immutable-version treatment:
    boot-time `Concilio.Councils.sync_static_templates!` compares
    the live module's `__council__/0` output against the latest
    persisted `spec_json`; if it drifts, a new version is inserted
    and `current_version_id` flips. Old runs keep resolving against
    their pinned version.
  - `spec_json` is a plain JSON-shaped map (no `:erlang.term_to_binary`).
- **`runs`** — One execution.
  - `run_id` is the council_ex `RunState.new/1` string id.
  - `status: :running | :ok | :partial | :error | :cancelled | :stuck`.
  - Single-writer: only `Concilio.RunRecorder` mutates this row after
    insertion.
  - `parent_run_id` links re-runs back to the original.
  - `responder_kind: :model | :council` — the path that produced it.
  - Aggregate counters (`total_*`) populated on finalize.
- **`run_events`** — Per-event row, ordered by `idx` per run.
  - `:member_token` chunks are intentionally **not** persisted.
  - `payload_json` is the JSON-shaped event tuple via
    `Concilio.Serialization.event_to_map/1`.
- **`conversations`** — Chat thread.
  - `default_responder_kind: :model | :council` plus
    `default_model` and/or `default_template_id`.
  - Soft-delete via `deleted_at`; hard-delete on demand.
- **`messages`** — One turn.
  - `role: :user | :assistant | :system`.
  - **Two shapes**:
    - **Plain turn** — `run_id == nil`, `model_used` set, `content`
      holds rendered text.
    - **Council turn** — `run_id` FK set, `template_id` +
      `template_version_id` set, `content` empty (rendered from
      `runs.result_json`).
- **`provider_settings`** — One row per provider atom.
  - `encrypted_credentials` is `Concilio.Crypto`-AES-GCM-encrypted.
  - `endpoint_override` for self-hosted / proxy / Azure. Validated
    on save: must be `http(s)://…` with a non-empty host or `nil`.
    Pasting an API key into this field is rejected by changeset.
- **`provider_models`** — One row per `(provider, model_id)` pair.
  - `source: :bundled | :user_added | :live_catalog | :local_detected`.
  - `in_working_set` — user's curated subset surfaced in pickers.
  - `last_test_*` — latest one-shot ping result.
  - `deprecated_at` — set on rows that drop out of the bundled
    catalog; kept forever so historical runs still resolve.
- **`app_state`** — Singleton row (`id = 1`). The integer primary
  key plus the single insert path in `Concilio.Auth` enforces
  uniqueness; the originally-planned DB-level CHECK was dropped
  because SQLite does not support `ALTER TABLE ADD CONSTRAINT`.
  - `token_hash` — Argon2 hash of the auth token.
  - `secret` — rotating session secret (logout rotates → kicks every
    cookie).
  - `kv` — free-form JSON map (TEXT under SQLite's JSON1, JSONB under
    Postgres) for per-app state.

---

## 2. Process tree

```
Concilio.Application (one_for_one)
├── ConcilioWeb.Telemetry
├── Concilio.Repo                                   ← SQLite (default) or Postgres
├── DNSCluster
├── Phoenix.PubSub (name: Concilio.PubSub)          ← shared bus
├── Oban (single instance, all queues)
│   └── Cron plugin: Cleanup @ 03:17 nightly
├── DynamicSupervisor (Concilio.RunRecorder.Supervisor)   ← hosts RunRecorder GenServers
├── DynamicSupervisor (Concilio.RunSupervisor)            ← caller-owned home for council_ex RunServers
├── DynamicSupervisor (Concilio.RunReplayer.Supervisor)
├── Concilio.Auth.RateLimiter (GenServer + ETS)
├── Concilio.Settings (GenServer)                   ← ~/.concilio/settings.toml cache
├── Concilio.Auth.Bootstrapper (one-shot Task)      ← first-boot token
├── Concilio.Councils.Bootstrapper (one-shot Task)  ← static discovery
├── Concilio.Providers.Bootstrapper (one-shot Task) ← catalog + runtime
└── ConcilioWeb.Endpoint
```

`council_ex` runs **its own** runner supervisor inside the council_ex
application; we do **not** put any council_ex modules in our tree
(a hard rule — see `CLAUDE.md`). We do, however, register a
caller-owned `Concilio.RunSupervisor` (a plain `DynamicSupervisor`) and
pass it as `supervisor:` to `CouncilEx.start_supervised_run/3`, so the
RunServers council_ex spawns are hosted under our tree and shut down
cleanly with the app. The bundled `CouncilEx.Runner.Supervisor` stays
running but is unused.

---

## 3. Key data flows

### 3.1 Council run (run-now or summon)

```
LiveView → ConcilioWeb.RunStarter.start/3
         │
         ├─ normalize_input/1                     ← binary → %{question: text}
         │                                          map → as-is
         ├─ precheck (provider/model availability)
         ├─ resolve module-form OR build %CouncilEx.DynamicCouncil{}
         ├─ CouncilEx.validate/1                  ← belt-and-suspenders pre-spawn
         └─ DynamicSupervisor.start_child(
              Concilio.RunRecorder.Supervisor,
              {Concilio.RunRecorder, %{council, input, template, version, run_opts}}
            )
            └─ RunRecorder.init/1 (in the recorder process):
                 ├─ CouncilEx.start_supervised_run(council, input,
                 │      subscribe: true,
                 │      supervisor: Concilio.RunSupervisor,
                 │      relay_topics: ["concilio:runs"])
                 │      ↑ subscribe: true installs the PubSub subscription
                 │        on THIS process before the RunServer is spawned —
                 │        kills the documented :run_started race.
                 └─ Concilio.Runs.insert!(run_id, input, ...)  ← placeholder row

         RunStarter then GenServer.call(pid, :get_run) and returns {:ok, run}.

council_ex picks up provider creds via Application.get_env(:council_ex, :providers)
populated by Concilio.Providers.Runtime.

Both call sites receive the SAME normalized map so DB persistence
matches what council_ex actually ran against. (Was a bug in early
M9; see CHANGELOG fix `cf72cda`.)

council_ex Runner ─broadcasts─► Concilio.PubSub
                                "council_ex:run:#{run_id}"   ← per-run topic
                                "concilio:runs"              ← relay (every run)

                                          ▼
        ┌────────────────────────────────────────────────┐
        │              Concilio.RunRecorder              │
        │  GenServer subscribed via subscribe: true      │
        │  in init/1 (no race window).                   │
        │                                                │
        │  for each event:                               │
        │    Runs.append_event!(run, idx, type, ev)      │
        │  on terminal:                                  │
        │    Runs.finalize!(run, result)  OR             │
        │    Runs.mark_status!(run, :error|:cancelled)   │
        │  then {:stop, :normal, _} (transient).         │
        └────────────────────────────────────────────────┘

LiveView (chat or run detail) also subscribes to the per-run topic for
UI updates. LV is read-only on `runs` / `run_events`; the recorder
owns those writes (single-writer rule). The `"concilio:runs"` relay
topic has no subscribers today — it's a free hook for a future global
activity feed.
```

### 3.2 Replay

```
User clicks "Replay" on /runs/:id
         │
         ▼
Concilio.RunReplayer.start(run_id, db_run_id, speed: 1.0)
         │
         ├─ DynamicSupervisor child
         ├─ Reads run_events rows in idx order
         └─ Re-broadcasts on "concilio:replay:#{run_id}"
                with original timing scaled by `speed`.

RunDetailLive in :replay mode subscribes to that topic and animates
the timeline as if live.
```

### 3.3 Plain (single-model) chat turn

```
ChatLive submit
  └─ resolve_responder(conv) — reads conv.default_model ("provider:model_id")
       │   set by the per-chat model picker in the composer (phx-change "set_model")
       │   stored on conversations.default_model + default_responder_kind=:model
       └─ on :error → keep composer text + flash; do NOT append user msg
  └─ Chats.append_user_message
  └─ assign :pending_started_at = System.system_time(:millisecond)
  └─ push_event "concilio:set_composer" %{text: ""}        (clears textarea via ComposerKeys hook)
  └─ push_event "concilio:scroll_to_bottom" %{}            (force-pins AutoScroll)
  └─ start_async(:plain_completion, fn ->
       Concilio.Chats.Completion.run(provider, model, history, opts)
     end)
       │   history = Concilio.Chats.History.build(messages)
       │     - flattens Message rows to [%{role, content}]
       │     - council assistant rows (content="") hydrate from
       │       run.result_json["final"]["content"] so model swaps see
       │       what the council said

Concilio.Chats.Completion
  └─ resolves Application.get_env(:council_ex, :providers)[provider]
  └─ builds %CouncilEx.Request{messages, model, ...}
  └─ CouncilEx.Providers.Instructor.complete(request, opts)

LV handle_async(:plain_completion, {:ok, {:ok, content}}, ...)
  └─ Chats.append_plain_assistant(conv, "provider:model", content)
  └─ refreshes messages stream
  └─ clears :pending_started_at, :last_sent_text
  └─ Oban: AutoTitle (if conv untitled, scheduled by append_plain_assistant)

LV handle_async(:plain_completion, {:ok|:exit, error}, ...)
  └─ flashes error
  └─ restore_composer/1 → push_event "concilio:set_composer" %{text: last_sent_text}
       so user can edit + resend without retyping
```

### 3.4 Council summon mid-conversation

```
ChatLive summon submit
  └─ Chats.append_user_message
  └─ ConcilioWeb.RunStarter.start(template, text)
  └─ Chats.append_council_assistant(conv, %{run_id, template_id, ...})
  └─ Phoenix.PubSub.subscribe("council_ex:run:#{run_id}")
  └─ assign :active_run_id, :pending_started_at
  └─ push_event "concilio:scroll_to_bottom" %{}

Recorder owns runs.result_json. ChatLive refreshes the messages
stream on :run_completed / :run_failed / :run_cancelled and clears
:active_run_id + :pending_started_at via clear_council_pending/1.
```

### 3.5 Chat UI hooks (assets/js/hooks/)

```
ComposerKeys      Cmd/Ctrl+Enter on #composer-text → form.requestSubmit()
                  + handleEvent "concilio:set_composer" → set textarea.value
ElapsedTimer      data-start-ms → ticks innerText every 500ms (Thinking… counter)
AutoScroll        scroll-pinned tracking + handleEvent
                  "concilio:scroll_to_bottom" force-engages on user send
```

---

## 4. Module map

### 4.1 Domain (`lib/concilio/`)

| Module                                                                                                                                                             | Role                                                                                                                                                                                                                                                                                                                                                                                            |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Concilio.Application`                                                                                                                                             | Supervision tree root                                                                                                                                                                                                                                                                                                                                                                           |
| `Concilio.Repo`                                                                                                                                                    | Ecto repo (SQLite default; Postgres opt-in via `CONCILIO_DB=postgres` at compile time)                                                                                                                                                                                                                                                                                                          |
| `Concilio.Release`                                                                                                                                                 | Migrate / rollback callable from `bin/concilio eval`                                                                                                                                                                                                                                                                                                                                            |
| `Concilio.AppState`                                                                                                                                                | Singleton-row schema                                                                                                                                                                                                                                                                                                                                                                            |
| `Concilio.Auth`                                                                                                                                                    | Token + secret + kv context                                                                                                                                                                                                                                                                                                                                                                     |
| `Concilio.Auth.Token`                                                                                                                                              | gen / hash / verify (Argon2)                                                                                                                                                                                                                                                                                                                                                                    |
| `Concilio.Auth.TokenStore`                                                                                                                                         | `~/.concilio/auth_token` 0600                                                                                                                                                                                                                                                                                                                                                                   |
| `Concilio.Auth.Bootstrapper`                                                                                                                                       | First-boot token gen Task                                                                                                                                                                                                                                                                                                                                                                       |
| `Concilio.Auth.RateLimiter`                                                                                                                                        | ETS sliding-window counter                                                                                                                                                                                                                                                                                                                                                                      |
| `Concilio.Crypto`                                                                                                                                                  | AES-256-GCM AEAD                                                                                                                                                                                                                                                                                                                                                                                |
| `Concilio.Councils`                                                                                                                                                | Templates context                                                                                                                                                                                                                                                                                                                                                                               |
| `Concilio.Councils.Template`                                                                                                                                       | Template schema                                                                                                                                                                                                                                                                                                                                                                                 |
| `Concilio.Councils.TemplateVersion`                                                                                                                                | Immutable version schema                                                                                                                                                                                                                                                                                                                                                                        |
| `Concilio.Councils.Bootstrapper`                                                                                                                                   | Static-template discovery Task (boot-only; restart `mix phx.server` to pick up new modules)                                                                                                                                                                                                                                                                                                     |
| `Concilio.Councils.{Demo, Critique, Iterative, PeerReview}`                                                                                                        | Original 4 declarative bundled templates (single-provider, OpenAI)                                                                                                                                                                                                                                                                                                                              |
| `Concilio.Councils.WeightedPanel`                                                                                                                                  | 3 Echo + `CouncilEx.Rounds.WeightedSynthesis` (`expose_confidence: true`) + Synthesizer chair. Wu et al. _Council Mode_ weighted-consensus topology (arXiv:2604.02923). Members carry `confidence: :self_report`.                                                                                                                                                                               |
| `Concilio.Councils.Jury`                                                                                                                                           | 3 Echo judges + `CouncilEx.Rounds.Iterate` wrapping `:independent_analysis` (`max_iterations: 2`, retry until avg confidence ≥ 0.75) + Synthesizer chair. Judges DO NOT see each other across iterations — independent re-sample, not debate (Wu 2025, arXiv:2511.07784). Convergence guard via remote capture `&__MODULE__.__jury_converged__/2` so it survives JSON serialization.            |
| `Concilio.Councils.{Quickstart, Debate, MultiModelPanel, ParallelPanel, PresidentialDebate, CreativeJudge}`                                                        | Six expanded templates added 2026-05-06; `MultiModelPanel` spans openai + anthropic + gemini                                                                                                                                                                                                                                                                                                    |
| `Concilio.Councils.Members.{Echo, Synthesizer}`                                                                                                                    | Original generic member + chair                                                                                                                                                                                                                                                                                                                                                                 |
| `Concilio.Councils.Members.{Advocate, Skeptic, Optimist, Pro, Con, Moderator, Pragmatist, Liberal, Conservative, Progressive, Libertarian, Pundit, Writer, Judge}` | Per-role members for the expanded templates                                                                                                                                                                                                                                                                                                                                                     |
| `Concilio.Runs`                                                                                                                                                    | Runs context                                                                                                                                                                                                                                                                                                                                                                                    |
| `Concilio.Runs.Run`                                                                                                                                                | Run schema                                                                                                                                                                                                                                                                                                                                                                                      |
| `Concilio.Runs.RunEvent`                                                                                                                                           | Event schema                                                                                                                                                                                                                                                                                                                                                                                    |
| `Concilio.RunRecorder`                                                                                                                                             | Single-writer GenServer; owns `start_supervised_run` call + subscribe + persistence                                                                                                                                                                                                                                                                                                             |
| `Concilio.RunReplayer`                                                                                                                                             | GenServer per replay session                                                                                                                                                                                                                                                                                                                                                                    |
| `Concilio.Serialization`                                                                                                                                           | JSON-shaped event payloads. Handles function captures, pids, refs, ports via `inspect/1` so static-template specs that carry runtime callbacks (e.g. `Jury`'s `until: &__MODULE__.__jury_converged__/2` in an `Iterate` round) round-trip through `spec_json` without crashing Jason.                                                                                                           |
| `Concilio.Chats`                                                                                                                                                   | Conversations + messages context                                                                                                                                                                                                                                                                                                                                                                |
| `Concilio.Chats.Conversation`                                                                                                                                      | Conversation schema                                                                                                                                                                                                                                                                                                                                                                             |
| `Concilio.Chats.Message`                                                                                                                                           | Message schema (two-path)                                                                                                                                                                                                                                                                                                                                                                       |
| `Concilio.Chats.Completion`                                                                                                                                        | Single-model direct provider call                                                                                                                                                                                                                                                                                                                                                               |
| `Concilio.Chats.History`                                                                                                                                           | Flattens messages → `[%{role, content}]`. Hydrates council assistant rows from `run.result_json["final"]["content"]` so model swaps + plain follow-ups see council outputs.                                                                                                                                                                                                                     |
| `Concilio.Providers`                                                                                                                                               | Settings + models context + bridge taps                                                                                                                                                                                                                                                                                                                                                         |
| `Concilio.Providers.Setting`                                                                                                                                       | provider_settings schema                                                                                                                                                                                                                                                                                                                                                                        |
| `Concilio.Providers.Model`                                                                                                                                         | provider_models schema                                                                                                                                                                                                                                                                                                                                                                          |
| `Concilio.Providers.Catalog`                                                                                                                                       | Hardcoded curated lists per provider (openai/anthropic/openrouter/ollama/gemini after the 2026-05-07 groq+mistral removal)                                                                                                                                                                                                                                                                      |
| `Concilio.Settings`                                                                                                                                                | GenServer-cached, file-backed user prefs at `~/.concilio/settings.toml`. `Defaults` struct (council slug, chairman model, member timeout, failure mode) snapshotted into run opts by `RunStarter.start/3`; `Display` struct (theme, stream*tokens) read by root layout SSR. Self-heals across hot-reload via lazy `ensure*\*` guards; falls back to direct disk read when GenServer is missing. |
| `Concilio.Providers.Tester`                                                                                                                                        | One-shot ping (stub today)                                                                                                                                                                                                                                                                                                                                                                      |
| `Concilio.Providers.Runtime`                                                                                                                                       | DB → council_ex env bridge. `:ollama` opts come from `CouncilEx.Provider.Adapters.Ollama.default_opts/1` (preset over the OpenAI-compat adapter, NOT a standalone adapter)                                                                                                                                                                                                                      |
| `Concilio.Providers.Bootstrapper`                                                                                                                                  | Boot-time catalog sync + bridge                                                                                                                                                                                                                                                                                                                                                                 |
| `Concilio.Workers.AutoTitle`                                                                                                                                       | Oban: auto-title untitled convos                                                                                                                                                                                                                                                                                                                                                                |
| `Concilio.Workers.Cleanup`                                                                                                                                         | Oban: nightly run_events prune                                                                                                                                                                                                                                                                                                                                                                  |

### 4.2 Web (`lib/concilio_web/`)

| Module                            | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ConcilioWeb`                     | `:controller`, `:live_view`, `:html`, `:router` macros                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `ConcilioWeb.Endpoint`            | Phoenix endpoint (Bandit)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `ConcilioWeb.Router`              | Pipelines + routes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `ConcilioWeb.Auth`                | Plugs + LV `on_mount` hook                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `ConcilioWeb.SessionController`   | POST /login, DELETE /logout                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `ConcilioWeb.RunStarter`          | LV ↔ `CouncilEx.start_run/3` glue                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `ConcilioWeb.LoginLive`           | Token paste form                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `ConcilioWeb.ChatLive`            | / and /c/:id. Viewport-locked layout (`flex h-[calc(100dvh-8rem)]`): sidebar (conversations only — main-nav links removed) + chat column with internal scroll on `#chat-scroll` (`AutoScroll` hook) and pinned composer at the bottom. Composer hosts the **per-chat model picker** (`<select phx-change="set_model">`, `optgroup` per provider, stale-model row preserved + labeled `(not in working set)`), the **+ Summon council** button (`btn btn-secondary btn-outline btn-sm`), and the textarea with `ComposerKeys` hook (Cmd/Ctrl+Enter submits). On send: clears textarea via `concilio:set_composer` push_event, force-pins via `concilio:scroll_to_bottom`, sets `:pending_started_at` (drives "Thinking…" bubble + `ElapsedTimer` hook). On model error: restores `last_sent_text` so user can resend. Each assistant row shows duration in chat-header (`format_duration_ms/1`) — plain = `inserted_at - prior user inserted_at`, council = `run.finished_at - run.started_at`. **Empty state** when `is_nil(@conversation)` shows centered hero with "+ New conversation" button (composer + thread hidden until conv exists). **Title editing** is inline: click title → `<input>` + Save/Cancel (Escape cancels via `phx-keydown`); empty title falls back to `display_title/1` = `"New chat · Mon D, HH:MM"` from `inserted_at`. Plain follow-ups read history via `Concilio.Chats.History.build/1` so council outputs survive model switches. |
| `ConcilioWeb.CouncilIndexLive`    | /councils — cards show provider-color badges per `Concilio.Councils.spec_requirements/1`; non-runnable templates dim with "Needs: provider/model" via `Providers.missing_requirements/1`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `ConcilioWeb.CouncilShowLive`     | /councils/:id — two diagrams switched via `?view=flow` (default) and `?view=rounds`. **Flow** = HEEx swim-lanes (rounds top-to-bottom, members per row, chair last). **Rounds** = cytoscape trellis: each member duplicated once per round, edges from prev-round outputs to next-round inputs follow per-round routing semantics (`independent` → input only, `revision` → self-only, `peer_review` / `debate` / `custom` → full crossbar), chair fed by final round (synthesize). Input/independent edges dashed. Routing types inferred by `infer_round_type/2` heuristic. The 2026-05-06 collapsed "Topology" view was dropped on 2026-05-07 — Rounds is strictly more informative.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `ConcilioWeb.CouncilBuilderLive`  | /councils/new + /councils/:id/edit. Full-DSL-parity form for dynamic councils: rounds editor, member/chair role + overrides + tools + output schema (registered or inline JSON) + sub-council picker; council-level `default_profile`/`router`/`tools`/`metadata`. Right-side sticky pane reuses `CouncilDiagram` cytoscape hook for live preview. See `CLAUDE.md` hard rule #9 for the persisted spec_json shape.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `ConcilioWeb.RunIndexLive`        | /runs                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `ConcilioWeb.RunDetailLive`       | /runs/:id                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `ConcilioWeb.SettingsLive`        | /settings/:tab — `/settings` defaults to `:providers`. Tabs: Providers (splits into **Enabled** full cards vs **Available** chip strip), Defaults (file-backed user defaults via `Concilio.Settings`: council slug, chairman model, member timeout, failure mode), Display (theme + token-streaming toggle), About. Storage tab dropped 2026-05-07.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `ConcilioWeb.CoreComponents`      | Phoenix scaffold components (forms use DaisyUI 5 fieldset/legend)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `ConcilioWeb.Components.Markdown` | `<.markdown body=… />` via earmark                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `ConcilioWeb.Layouts`             | Layouts.app + theme_toggle + flash_group                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |

### 4.3 Mix tasks (`lib/mix/tasks/`)

| Task                       | Purpose                              |
| -------------------------- | ------------------------------------ |
| `mix concilio.reset_token` | Regenerate auth token, rotate secret |

### 4.4 Migrations (`priv/repo/migrations/`)

In order:

1. `add_oban` (`Oban.Migration.up()`)
2. `create_app_state` (singleton row, CHECK id = 1)
3. `create_council_templates`
4. `create_council_template_versions` (+ FK from templates)
5. `create_runs`
6. `create_run_events`
7. `create_conversations`
8. `create_messages`
9. `create_provider_settings`
10. `create_provider_models`

---

## 5. Boot sequence

```
1. Application.start → supervision tree boots in declared order
2. Repo opens its connection pool
3. Oban kicks off (queues idle until cron / inserts arrive)
4. RunRecorder.Supervisor (DynamicSupervisor for recorder GenServers),
   RunSupervisor (DynamicSupervisor passed to start_supervised_run as
   the host for council_ex RunServers), RunReplayer.Supervisor — all
   ready but empty
5. Auth.RateLimiter creates its ETS table
6. Auth.Bootstrapper (transient Task):
     - inserts app_state row if missing
     - rotates secret if missing
     - generates token + writes ~/.concilio/auth_token + prints + hashes
7. Councils.Bootstrapper (transient Task):
     - sync_static_templates! upserts every Concilio.Councils.* with
       __council__/0
8. Providers.Bootstrapper (transient Task):
     - sync_bundled_catalog! reconciles the hardcoded list into
       provider_models (insert / deprecate)
     - Runtime.refresh! pushes decrypted creds into
       Application.put_env(:council_ex, :providers, ...)
9. Endpoint binds the HTTP port
```

Disabled in `:test` via three `:start_*_bootstrapper?` config flags.

---

## 5a. UI conventions

- **Forms** use the DaisyUI 5 native pattern:

  ```heex
  <fieldset class="fieldset">
    <legend class="fieldset-legend">Label</legend>
    <input class="input w-full" … />
    <p class="fieldset-label">Optional helper text</p>
  </fieldset>
  ```

  `form-control` (DaisyUI 4) is gone. `ConcilioWeb.CoreComponents.input/1`
  emits this shape so every `<.input field=…>` call gets it free.

- **Modals** use `<dialog class="modal modal-open">` for native a11y;
  modal box constrained to `max-w-lg` for forms.
- **Layouts.app** takes a `:max_w` attr (default `max-w-7xl`).
  Form-heavy pages opt down to `max-w-4xl`; index pages use
  `max-w-6xl`; chat / run-detail use the full `max-w-7xl`.
- **Status badges** + table rows use DaisyUI's `badge-success`,
  `badge-warning`, `badge-error`, `badge-ghost` for run state.

## 5b. Dev tooling

- **Tidewave** — plugged into the endpoint
  (`lib/concilio_web/endpoint.ex`) in dev. Exposes an MCP server at
  `/tidewave/mcp` for IEx eval, log inspection, and source jump-to
  from any MCP-aware client (Claude Code, Cursor). Register with
  `claude mcp add tidewave http://localhost:4000/tidewave/mcp`.
- **Phoenix LiveDashboard** — at `/dev/dashboard` when
  `:concilio, :dev_routes` is true.

## 6. Integration points with council_ex

We consume `:council_ex` as a Hex dependency.

Concrete integration surfaces:

- **PubSub adapter** — configured in `config/config.exs`:

  ```elixir
  config :council_ex,
    pubsub: {CouncilEx.PubSub.Phoenix, name: Concilio.PubSub}
  ```

  Every council_ex event lands on our Phoenix.PubSub.

- **Provider config** — populated at runtime by
  `Concilio.Providers.Runtime` on every cred change. council_ex reads
  `Application.get_env(:council_ex, :providers, [])[provider_id]` per
  member dispatch.

- **Run lifecycle** — `Concilio.RunRecorder` (GenServer) calls
  `CouncilEx.start_supervised_run/3` from inside its own `init/1` with:
  - `subscribe: true` — installs the per-run subscription on the
    recorder process before the RunServer broadcasts, eliminating the
    `:run_started` race documented in
    `council_ex/docs/RUNNING_IN_PHOENIX.md` §3.
  - `supervisor: Concilio.RunSupervisor` — caller-owned host so runs
    shut down with the app and a future tenant cleanup can sweep them.
  - `relay_topics: ["concilio:runs"]` — every event also broadcasts to
    a stable global topic for a future activity feed (no consumer yet).

  Cancel still goes through `CouncilEx.cancel/1` (cooperative). Force
  termination via `CouncilEx.terminate_run/1` is wired in the API but
  not yet exposed in the UI.

- **Static councils** — `use CouncilEx` modules under
  `Concilio.Councils.*` are auto-discovered as templates.

- **Member modules** — `Concilio.Councils.Members.Echo` and
  `Synthesizer` use `CouncilEx.Member` with `role/1` +
  `system_prompt/1`. Real opinionated councils ship later.

- **Dynamic councils** — `RunStarter.start/3` hydrates a
  `CouncilEx.DynamicCouncil` from `template_version.spec_json` via
  `RunStarter.build_dynamic_council/2` (`@doc false` public, exposed
  for tests). The persisted spec carries every `DynamicMember` /
  `DynamicCouncil` field the runtime understands (see `CLAUDE.md`
  hard rule #9 for the exact `spec_json` shape).
  `dynamic_member_attrs/1` lifts numeric overrides
  (`temperature`, `max_tokens`) into `profile_overrides`, propagates
  `role` / `profile` / `tools` / `output_schema` /
  `output_schema_inline` / `sub_council` / `input_mapper` onto the
  member map, and silently drops malformed shapes (validation lives
  in `DynamicCouncil.validate/1`).

- **Registry** — `config :council_ex, :registry` in
  `config/config.exs` seeds bundled profiles + schemas under stable
  string names so the builder's profile / output-schema selects
  aren't empty. Tools, routers, sub-councils, and input-mappers stay
  empty by default; register at runtime via
  `CouncilEx.Registry.register_*/2` or extend the config block.

We **do not**:

- Modify `council_ex` (a hard rule — see `CLAUDE.md`).
- Supervise `council_ex` modules — its own
  `CouncilEx.Application` does that.
- Use a separate Oban/Repo — one of each, both Phoenix scaffold's.

---

## 7. PubSub topic catalog

| Topic                         | Producer                                | Subscribers                                                                                                                                                                    |
| ----------------------------- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `"council_ex:run:#{run_id}"`  | `council_ex` Runner                     | `Concilio.RunRecorder` (always; subscribes via `subscribe: true` in its `init/1` before the RunServer spawns), `ChatLive` (during summon), `RunDetailLive` (when not terminal) |
| `"concilio:runs"`             | `council_ex` Runner via `:relay_topics` | (none today — reserved for future global activity feed)                                                                                                                        |
| `"concilio:replay:#{run_id}"` | `Concilio.RunReplayer`                  | `RunDetailLive` (in :replay mode)                                                                                                                                              |

Tuple shapes are reused byte-for-byte from `CouncilEx.Events`. The
`{type, run_id, ...args}` form is the canonical contract.

---

## 8. Quality gates

Run at every milestone close (NOT per commit, per user directive):

```sh
mix format
mix credo --strict
mix dialyzer
mix test
```

Targets: 0 issues, 0 errors (5 macro-injected false-positives skipped
via `.dialyzer_ignore.exs`), all tests pass.

`mix precommit` is the lighter pre-commit gate (compile +
deps.unlock --unused + format + test).

---

## 9. Key architecture decisions

The load-bearing choices behind the design above:

1. **SQLite default + Postgres opt-in (2026-05-08)**, supersedes
   the earlier "Postgres, not SQLite" pick. Drives the data dir
   convention (`~/.concilio/`), the auto-migrate hook in
   `Concilio.Application`, and the per-platform release path.
2. **Tailwind + DaisyUI, not shadcn-phx.**
3. **Hex dependency on `council_ex`** (consumed as a published package).
4. **Token auth replaces 6-digit PIN.**
5. **Two-path message rendering** (plain vs council).
6. **Per-model working set** with per-row test ⚡.
7. **Recorder owns all `runs` / `run_events` writes** (single-writer).
8. **Run detail auto-flips `:live` → `:static` on completion.**
9. **Multi-tab same conversation: accept parallel runs**, no lock.
10. **Per-summon council overrides are ephemeral** (no new version row).

---

## 10. Open follow-ups (post-`v0.1.0`)

These shipped in `0.1.0` (see `CHANGELOG.md`):

- **M8.5** — Provider runtime bridge. ✅
- **M8.6** — Onboarding gate + wider layouts + view polish. ✅
- **M9** — Real plain-chat completion + real Tester ⚡ ping +
  markdown rendering. ✅
- **Future** — FTS5/pg_trgm conversation search, date-bucket
  sidebar grouping, in-place title editing, pin/archive UI,
  durable runs (`council_ex_oban`), persistence library extraction
  (`council_ex_ecto`), multi-user / hosted SaaS.

When something here lands, update the relevant section + the
CHANGELOG.
