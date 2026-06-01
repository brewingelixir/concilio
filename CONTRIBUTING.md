# Contributing to Concilio

Thanks for thinking about contributing. This is a single-developer
project today; the bar to land a PR is intentionally simple.

## Dev setup

1. Install Erlang/OTP 27 and Elixir 1.18. The `.tool-versions` file
   pins exact versions; `mise install` (or `asdf install`) reads it.
2. `mix setup` — fetches deps (including `council_ex` from Hex),
   creates the SQLite dev database, runs migrations, and builds
   assets. **No external database to install:** Concilio uses SQLite
   by default, stored at `priv/repo/concilio_dev.db`. (Postgres is an
   opt-in, compile-time backend — see the README's "Storage backend"
   section — and is not needed for development.)
3. `./scripts/dev server` (or `mix phx.server`) — runs at
   <http://localhost:4000>. The first boot prints an auth token;
   paste it on `/login`.

For dev convenience set `CONCILIO_NO_AUTH=true` to skip the login
flow.

## Tests + checks

```sh
mix precommit
```

The `precommit` alias compiles with warnings-as-errors, removes
unused deps from the lockfile, formats, and runs the test suite.

At milestone close (or before submitting a PR for non-trivial
changes), also run:

```sh
mix credo --strict
mix dialyzer
```

`mix dialyzer` is expected to be clean (it builds a PLT on first run,
~30s). `mix credo --strict` should report no warnings, though it may
still surface a few low-priority style suggestions.

## Conventions

- Read `AGENTS.md` and `CLAUDE.md` before non-trivial changes.
  Phoenix 1.8 / LiveView 1.1 idioms in this repo are tighter than
  the generated scaffolding suggests.
- Migrations: `mix ecto.gen.migration name_using_underscores`,
  never hand-named files.
- Commit style: `feat(scope): one-line summary`,
  `fix(scope): …`, `chore: …`. One concern per commit. Imperative
  voice.
- Don't push without explicit authorization; CI runs on PR.

## Filing issues

Reproducible bug reports are gold. Include:

- The Concilio + `council_ex` versions (`mix help concilio` near M9).
- Relevant log output from `mix phx.server`.
- Provider + model id involved, if any.
