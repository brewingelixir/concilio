defmodule Concilio.Providers.Tester do
  @moduledoc """
  One-shot test ping for a (provider, model). Issues a tiny chat
  completion request through the live council_ex provider opts (set
  up by `Concilio.Providers.Runtime`) and records the latency + status
  on the row.

  Prompt is `"Reply with the single word: pong"` — the prompt itself
  bounds output to roughly nothing on hosted providers. We deliberately
  send NO `max_tokens` / `temperature`: council_ex 0.1.0's OpenAI
  adapter emits the legacy `max_tokens` param, which gpt-5.x / o-series
  models reject (they require `max_completion_tokens`), and those models
  also reject `temperature != 1`. Omitting both keeps the ping
  compatible across every model family. See
  `docs/CONCILIO_OPEN_QUESTIONS.md`.
  """

  require Logger

  alias Concilio.Chats.Completion
  alias Concilio.Providers
  alias Concilio.Providers.Model

  @prompt [%{role: "user", content: "Reply with the single word: pong"}]

  @type result :: %{status: :ok | :error, latency_ms: integer(), error: String.t() | nil}

  @doc """
  Tests a single model and persists the result on the row.
  """
  @spec test(Model.t()) :: {:ok, Model.t()} | {:error, term()}
  def test(%Model{} = model) do
    started = System.monotonic_time(:millisecond)
    res = do_ping(model)
    finished = System.monotonic_time(:millisecond)

    if res.status == :error do
      Logger.warning(
        "Provider test failed: provider=#{model.provider} model=#{model.model_id} error=#{res.error}"
      )
    end

    Providers.record_test_result(model, Map.put(res, :latency_ms, finished - started))
  end

  defp do_ping(%Model{provider: :ollama, model_id: model_id}) do
    do_completion(:ollama, model_id)
  end

  defp do_ping(%Model{provider: provider, model_id: model_id}) do
    case Providers.get_api_key(provider) do
      {:ok, _key} ->
        do_completion(provider, model_id)

      :missing ->
        %{status: :error, error: "No API key configured for #{provider}."}

      :error ->
        %{status: :error, error: "Could not decrypt credentials for #{provider}."}
    end
  end

  defp do_completion(provider, model_id) do
    case Completion.run(provider, model_id, @prompt) do
      {:ok, _content} ->
        %{status: :ok, error: nil}

      {:error, %CouncilEx.Error{} = err} ->
        %{status: :error, error: format_error(err)}

      {:error, reason} ->
        %{status: :error, error: format_error(reason)}
    end
  rescue
    e ->
      Logger.warning(
        "Tester crashed: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      %{status: :error, error: "#{e.__struct__}: #{Exception.message(e)}"}
  end

  defp format_error(%CouncilEx.Error{kind: kind, reason: reason, message: msg}) do
    body = msg || inspect(reason, limit: :infinity, printable_limit: :infinity)
    "[#{kind}] #{body}"
  end

  defp format_error({:provider_not_configured, p}), do: "Provider #{p} not configured."
  defp format_error(other), do: inspect(other, limit: :infinity, printable_limit: :infinity)
end
