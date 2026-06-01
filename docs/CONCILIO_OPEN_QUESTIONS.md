# Concilio — Open Questions

Running log of unresolved questions and known gaps, primarily around
the `council_ex` integration. Per the project's hard rules (see
`CLAUDE.md` / `AGENTS.md`), Concilio consumes `council_ex` as a
published dependency and **does not** fork
or reach into its private state — so when the library is missing a
capability Concilio needs, the gap is recorded here rather than worked
around by patching the dep.

## How to use this file

- Add an entry when you hit a `council_ex` limitation, an ambiguous
  behavior, or a design question that blocks or shapes Concilio work.
- Keep entries short: what is unknown/blocked, why it matters, and the
  current workaround (if any).
- Resolve in place — move the resolution under the entry and mark it
  `Resolved (YYYY-MM-DD)`; don't delete the history.
- When a question turns into a decision, record the resolution here and
  point at the code or commit that implements it.

## Open

### OpenAI adapter emits legacy `max_tokens` (gpt-5.x / o-series reject it)

- **What:** `council_ex` 0.1.0's OpenAI adapter
  (`CouncilEx.Provider.Adapters.OpenAI.build_body/3`) puts the request's
  `max_tokens` (and `temperature`) straight into the chat-completions
  body. It has no `max_completion_tokens` path, and the adapter ignores
  provider `opts` for body construction, so a caller cannot inject the
  new param.
- **Why it matters:** gpt-5.x and o-series models **reject** `max_tokens`
  with HTTP 400 `unsupported_parameter` ("Use 'max_completion_tokens'
  instead") and also reject `temperature != 1`. Concilio's catalog is
  entirely gpt-5.x / gpt-4.1-era, so any code that sets `max_tokens`
  against an OpenAI model 400s. This bit the provider model-test ping
  and would bite **dynamic councils that set a per-member `max_tokens`
  override** on an OpenAI gpt-5.x model.
- **Current workaround:** Concilio sends **no** `max_tokens` /
  `temperature` for the model-test ping (`Concilio.Providers.Tester`) —
  the prompt bounds output. Bundled councils never set `max_tokens`, so
  they are unaffected. Plain chat passes no opts, also unaffected. There
  is **no** workaround for dynamic-council OpenAI `max_tokens` overrides
  short of a `council_ex` fix — avoid setting them on gpt-5.x members.
- **Wanted from `council_ex`:** emit `max_completion_tokens` (vs
  `max_tokens`) per model/endpoint, or accept an `extra_body` /
  param-name override in provider opts; and skip unsupported
  `temperature` for reasoning models.

## Resolved

_None recorded yet._
