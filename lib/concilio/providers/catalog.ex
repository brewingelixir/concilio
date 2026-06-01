defmodule Concilio.Providers.Catalog do
  @moduledoc """
  Bundled model catalog. Hand-curated per-provider lists ship with each
  Concilio release; users can add their own custom models via the
  Settings UI (those land with `source: :user_added`). Updates here are
  reconciled into the `provider_models` table on boot — new rows get
  inserted, missing ones are stamped `deprecated_at` (never deleted to
  keep historical runs intact).

  ## Updating this list

  See `docs/UPDATING_PROVIDER_CATALOG.md` for the full procedure.
  Short version:

  1. Pull the provider's current chat/reasoning model lineup from
     their docs (URLs in the docs file).
  2. Replace the per-provider list below with the model IDs you
     want surfaced. Use the **API model ID** verbatim (Concilio
     passes it through to the provider unchanged).
  3. Drop deprecated entries — the runtime reconciliation will
     mark any removed rows with `deprecated_at` so historical
     runs that referenced them still resolve.
  4. (Optional) add cost rows in `Concilio.Pricing` so run-detail
     metrics report token cost. Without a pricing row, runs still
     work but the cost column shows `nil`.
  """

  @type entry :: %{model_id: String.t(), label: String.t() | nil}

  @doc """
  Returns the list of entries for a provider.
  """
  @spec for_provider(atom()) :: [entry()]
  # Last reviewed: 2026-05-08. See
  # `docs/UPDATING_PROVIDER_CATALOG.md` for the source URLs + how
  # to refresh.
  def for_provider(:openai),
    do: [
      %{model_id: "gpt-5.5-pro", label: "GPT-5.5 Pro"},
      %{model_id: "gpt-5.5", label: "GPT-5.5"},
      %{model_id: "gpt-5.4", label: "GPT-5.4"},
      %{model_id: "gpt-5.4-mini", label: "GPT-5.4 mini"},
      %{model_id: "gpt-5.4-nano", label: "GPT-5.4 nano"},
      %{model_id: "gpt-5.3-codex", label: "GPT-5.3 Codex"},
      %{model_id: "gpt-5.2-pro", label: "GPT-5.2 Pro (reasoning)"},
      %{model_id: "gpt-5.2", label: "GPT-5.2 (reasoning)"},
      %{model_id: "gpt-4.1", label: "GPT-4.1"},
      %{model_id: "gpt-4.1-mini", label: "GPT-4.1 mini"}
    ]

  def for_provider(:anthropic),
    do: [
      %{model_id: "claude-opus-4-7", label: "Claude Opus 4.7"},
      %{model_id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6"},
      %{model_id: "claude-haiku-4-5", label: "Claude Haiku 4.5"},
      %{model_id: "claude-opus-4-6", label: "Claude Opus 4.6"},
      %{model_id: "claude-sonnet-4-5", label: "Claude Sonnet 4.5"},
      %{model_id: "claude-opus-4-5", label: "Claude Opus 4.5"},
      %{model_id: "claude-opus-4-1", label: "Claude Opus 4.1"}
    ]

  def for_provider(:openrouter),
    do: [
      %{model_id: "deepseek/deepseek-v4-pro", label: "DeepSeek V4 Pro (via OR)"},
      %{model_id: "deepseek/deepseek-v4-flash", label: "DeepSeek V4 Flash (via OR)"},
      %{model_id: "deepseek/deepseek-v3.2", label: "DeepSeek V3.2 (via OR)"},
      %{model_id: "moonshotai/kimi-k2.6", label: "Kimi K2.6 (via OR)"},
      %{model_id: "moonshotai/kimi-k2.5", label: "Kimi K2.5 (via OR)"},
      %{model_id: "qwen/qwen3.6-max-preview", label: "Qwen3.6 Max (via OR)"},
      %{model_id: "qwen/qwen3.6-flash", label: "Qwen3.6 Flash (via OR)"},
      %{model_id: "z-ai/glm-5", label: "GLM 5 (via OR)"},
      %{model_id: "x-ai/grok-4.20", label: "Grok 4.20 (via OR)"},
      %{model_id: "x-ai/grok-4.1-fast", label: "Grok 4.1 Fast (via OR)"},
      %{model_id: "minimax/minimax-m2.7", label: "MiniMax M2.7 (via OR)"},
      %{model_id: "meta-llama/llama-4-maverick", label: "Llama 4 Maverick (via OR)"},
      %{model_id: "meta-llama/llama-4-scout", label: "Llama 4 Scout (via OR)"}
    ]

  def for_provider(:gemini),
    do: [
      %{model_id: "gemini-3.1-pro-preview", label: "Gemini 3.1 Pro (preview)"},
      %{model_id: "gemini-3-flash-preview", label: "Gemini 3 Flash (preview)"},
      %{model_id: "gemini-2.5-pro", label: "Gemini 2.5 Pro"},
      %{model_id: "gemini-2.5-flash", label: "Gemini 2.5 Flash"},
      %{model_id: "gemini-2.5-flash-lite", label: "Gemini 2.5 Flash-Lite"}
    ]

  # Last reviewed: 2026-05-08. Curated picks of laptop-friendly
  # general-purpose chat/instruct models. See
  # `docs/UPDATING_PROVIDER_CATALOG.md` for the source URLs +
  # selection criteria. Locally-installed models that aren't on
  # this list are still surfaced via `source: :local_detected`
  # when Ollama's `/api/tags` reports them, so users with custom
  # pulls don't lose them.
  def for_provider(:ollama),
    do: [
      %{model_id: "llama3.2:latest", label: "Llama 3.2 (3B)"},
      %{model_id: "qwen3:8b", label: "Qwen3 (8B)"},
      %{model_id: "gemma3:4b", label: "Gemma 3 (4B)"},
      %{model_id: "phi4-mini:latest", label: "Phi-4 mini (3.8B)"},
      %{model_id: "mistral:latest", label: "Mistral (7B)"}
    ]

  def for_provider(_), do: []

  @doc """
  All providers that participate in the bundled catalog.
  """
  alias Concilio.Providers.Setting

  @spec providers() :: [atom()]
  def providers, do: Setting.providers()
end
