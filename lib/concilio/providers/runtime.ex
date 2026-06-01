defmodule Concilio.Providers.Runtime do
  @moduledoc """
  Bridge between Concilio's `provider_settings` storage and council_ex's
  expected `Application.get_env(:council_ex, :providers, [])` keyword
  list.

  council_ex resolves a member's provider via:

      Application.get_env(:council_ex, :providers, [])[provider_id]

  The value must be a keyword list with `:adapter`, `:adapter`,
  and `:api_key` (string). This module reads every enabled
  `provider_settings` row, decrypts the API key via `Concilio.Crypto`,
  and writes the assembled keyword list with `Application.put_env/3`.

  Refresh in three places:

  1. **At boot** — `Concilio.Providers.Runtime.Bootstrapper` task fires
     after the providers catalog sync.
  2. **After every credential write** — `Concilio.Providers` calls
     `refresh!/0` from `set_api_key/2`, `set_enabled/2`, and
     `set_endpoint_override/2`.
  3. **On demand** — UI buttons or tests can call `refresh!/0` directly.

  The function is idempotent and safe to call repeatedly.
  """

  require Logger

  alias Concilio.Crypto
  alias Concilio.Providers.Setting
  alias Concilio.Repo
  alias CouncilEx.Provider.Adapters.Ollama, as: OllamaAdapter

  @app :council_ex
  @providers_key :providers

  @doc """
  Reads all enabled providers, decrypts credentials, and writes the
  assembled keyword list to the council_ex application env.

  Returns the list that was written (for inspection).
  """
  @spec refresh!() :: keyword()
  def refresh! do
    list =
      Repo.all(Setting)
      |> Enum.filter(& &1.enabled)
      |> Enum.flat_map(&entry_for/1)

    Application.put_env(@app, @providers_key, list)
    list
  end

  @doc """
  Returns the current keyword list as written to council_ex env.
  """
  @spec current() :: keyword()
  def current, do: Application.get_env(@app, @providers_key, [])

  # ── Per-row entry assembly ──────────────────────────────────────────

  defp entry_for(%Setting{provider: :ollama} = setting) do
    base = adapter_for(:ollama)

    base =
      if setting.endpoint_override,
        do: Keyword.put(base, :base_url, setting.endpoint_override),
        else: base

    [{:ollama, base}]
  end

  defp entry_for(%Setting{provider: provider, encrypted_credentials: nil}) do
    Logger.debug("Skipping provider #{provider}: no credentials")
    []
  end

  defp entry_for(%Setting{provider: provider, encrypted_credentials: ct} = setting) do
    case Crypto.decrypt(ct) do
      {:ok, key} ->
        opts = adapter_for(provider) |> Keyword.put(:api_key, key)

        opts =
          if setting.endpoint_override,
            do: Keyword.put(opts, :base_url, setting.endpoint_override),
            else: opts

        [{provider, opts}]

      :error ->
        Logger.error("Could not decrypt credentials for #{provider} — bad CONCILIO_SECRET?")
        []
    end
  end

  # ── Adapter wiring per provider ─────────────────────────────────────
  #
  # See `council_ex/docs/PROVIDERS.md`. Most providers use the
  # Instructor dispatcher with a concrete `adapter`.

  defp adapter_for(:openai) do
    [
      adapter: CouncilEx.Provider.Adapters.OpenAI
    ]
  end

  defp adapter_for(:anthropic) do
    [
      adapter: CouncilEx.Provider.Adapters.Anthropic
    ]
  end

  defp adapter_for(:gemini) do
    [
      adapter: CouncilEx.Provider.Adapters.Gemini
    ]
  end

  defp adapter_for(:openrouter) do
    [
      adapter: CouncilEx.Provider.Adapters.OpenRouter
    ]
  end

  defp adapter_for(:ollama) do
    OllamaAdapter.default_opts()
  end
end
