# Updating the bundled provider catalog

Concilio ships with a hand-curated list of models per provider in
`lib/concilio/providers/catalog.ex`. The list determines which models
the Settings → Providers picker surfaces by default. Users can still
add their own models via the **Add custom model** button (those land
with `source: :user_added` and are never touched by reconciliation).

This doc is the procedure for refreshing the bundled list when a
provider ships new models or retires old ones.

## When to update

- A provider announces new generations (e.g. GPT-5.6, Claude Opus
  4.8, Gemini 4.0).
- A provider deprecates / retires a model the catalog still lists.
  The runtime reconciliation will mark removed rows with
  `deprecated_at` so historical runs still resolve, but new
  conversations should not surface deprecated IDs.
- A provider's API renames an existing model ID (rare, but happens —
  e.g. shadow-rename of preview to GA).

Cadence: review at minimum once a quarter. The Last reviewed:
`YYYY-MM-DD` comment above each provider's list in `catalog.ex` is
the timestamp.

## Procedure

For each provider:

1. **Open the provider's official docs** (URLs below).
2. **Pull the current chat / reasoning model lineup**. Skip:
   - embedding, audio (whisper / TTS), image (DALL-E, gpt-image),
     transcription, moderation, code-completion-only models
   - deprecated / legacy / fine-tunes / private model IDs
3. **Use the exact API model ID** the provider expects on requests.
   Concilio forwards it unchanged to the provider — typos are silent
   "model not found" errors at runtime.
4. **Edit the per-provider clause in
   `lib/concilio/providers/catalog.ex`**. Update the
   `Last reviewed: YYYY-MM-DD` comment to today.
5. (Optional) **Add pricing rows in `Concilio.Pricing`** for new
   IDs. Without a row, run metrics still record token counts but
   cost shows `nil`. Pricing pages are usually next to the model
   docs.
6. **Run `mix test`** — catalog reconciliation runs on app boot, so
   the test boot will surface compile errors and basic shape issues.
7. **Bump the Concilio version** + add a CHANGELOG entry under
   "Catalog updates" if the diff is user-visible.

## Source URLs per provider

### OpenAI

- All chat/reasoning models with API IDs:
  <https://developers.openai.com/api/docs/models/all>
- Latest model overview:
  <https://developers.openai.com/api/docs/guides/latest-model>
- Model release notes (current generation pages):
  <https://openai.com/index/introducing-gpt-5-5/>
- Deprecations (read this every time):
  <https://developers.openai.com/api/docs/deprecations>
- Retirement notices (ChatGPT-side, often signal API direction):
  <https://openai.com/index/retiring-gpt-4o-and-older-models/>

What to bundle: frontier (`-pro` / no-suffix), affordable mid-tier
(`-mini`, `-nano`), reasoning specialists (`gpt-5.2-pro`,
`gpt-5.2`), and one or two specialist agents (`gpt-5.3-codex`).
Diversity is more valuable than a long list — councils benefit from
different cognitive shapes (frontier vs reasoning vs fast/cheap).

### Anthropic

- Model overview + IDs:
  <https://docs.claude.com/en/docs/about-claude/models>
- Model release notes:
  <https://docs.claude.com/en/docs/about-claude/models/whats-new>

What to bundle: Opus / Sonnet / Haiku from the latest two major
generations. Older Opus generations (e.g. 4.1, 4.5) often stay
useful for council diversity; keep one or two.

### Gemini (Google AI Studio)

- Model + ID listing:
  <https://ai.google.dev/gemini-api/docs/models>

What to bundle: pro + flash variants of the current generation, plus
flash-lite if available. Skip preview tags unless they're stable
enough to be the only option for a feature.

### OpenRouter

- Live catalog (machine-readable):
  <https://openrouter.ai/api/v1/models>
- Web view:
  <https://openrouter.ai/models>

OpenRouter is the **exception**. The catalog file lists a curated
subset, but the runtime can also pull the live `/v1/models` endpoint
and let users opt into anything (`source: :live_catalog`). Keep the
bundled list small — hot picks worth surfacing without a live fetch.
Diverse non-OpenAI / non-Anthropic frontier models are the highest
value here (DeepSeek, Kimi, Qwen, GLM, Grok, Llama, MiniMax).

### Ollama

- Library home (popularity + tags):
  <https://ollama.com/library>
- Per-model pages: `https://ollama.com/library/<model>`

Ollama is a hybrid catalog. The bundled list is a small curated set
of laptop-friendly general-purpose models so users see something
useful out of the box; whatever else they have pulled locally still
shows up via Ollama's `/api/tags` endpoint (`source:
:local_detected`).

Selection criteria for bundled Ollama picks:

- **General-purpose chat/instruct only.** Skip vision-only, code-
  only fine-tunes, embedding, or specialty models — those belong in
  user-added.
- **≤8B parameters at default tag**, runnable on a typical 16 GB
  laptop with 4-bit quantization.
- **One model per major family** for council diversity (Llama, Qwen,
  Gemma, Phi, Mistral). 5 entries total is the cap; longer lists
  invite stale picks.
- **Pin the canonical tag** the maintainer recommends. `:latest`
  works for the obvious entry; explicit `:Nb` for sizes that need
  disambiguation (e.g. `qwen3:8b`).
- No pricing rows — Ollama is free local inference.

## Notes for agents reading this

- **Always research before editing.** Models change generation IDs
  silently (e.g. provider drops the date suffix on a "latest" alias).
  Hardcoding from memory will plant subtle bugs that surface as
  "model not found" at runtime.
- **Use WebFetch / WebSearch** to pull the official docs above.
  Compare against `mix.exs` build date — anything older than ~3
  months should be reverified.
- **Don't paraphrase the model IDs.** Copy verbatim. Even the case
  matters with some providers.
- **Skip preview / experimental IDs by default.** They'll get pulled
  out from under us. Wait for GA.
- **Update the `Last reviewed` comment** in `catalog.ex` so the next
  pass knows when to start fresh.
