defmodule Concilio.Chats.Completion do
  @moduledoc """
  Single-model direct completion. Bypasses the council pipeline for
  plain chat turns — no rounds, no chairman, no per-member events.

  Resolves provider opts from the same `Application.get_env(:council_ex,
  :providers, [])` slot that `Concilio.Providers.Runtime` populates,
  then invokes `CouncilEx.Providers.Instructor.complete/2` with a
  one-shot request.

  Returns `{:ok, content}` with the assistant text or `{:error, term}`.
  """

  alias CouncilEx.Error
  alias CouncilEx.Providers.Instructor
  alias CouncilEx.Request
  alias CouncilEx.Response

  @type provider_id :: atom()

  @doc """
  One-shot completion against a (provider, model) using the given
  messages list (each `%{role: "user" | "assistant" | "system",
  content: ...}`).
  """
  @spec run(provider_id(), String.t(), [map()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def run(provider, model, messages, opts \\ [])
      when is_atom(provider) and is_binary(model) and is_list(messages) do
    case provider_opts(provider) do
      {:ok, provider_opts} ->
        request = build_request(model, messages, opts)

        case Instructor.complete(request, provider_opts) do
          {:ok, %Response{content: content}} when is_binary(content) ->
            {:ok, content}

          {:ok, other} ->
            {:error, {:unexpected_response, other}}

          {:error, %Error{} = err} ->
            {:error, err}
        end

      {:error, _} = err ->
        err
    end
  end

  defp provider_opts(provider) do
    case Application.get_env(:council_ex, :providers, [])[provider] do
      nil -> {:error, {:provider_not_configured, provider}}
      opts when is_list(opts) -> {:ok, opts}
    end
  end

  defp build_request(model, messages, opts) do
    %Request{
      model: model,
      messages: Enum.map(messages, &normalize_message/1),
      temperature: Keyword.get(opts, :temperature),
      max_tokens: Keyword.get(opts, :max_tokens)
    }
  end

  defp normalize_message(%{role: role, content: content}) when is_atom(role) do
    %{role: Atom.to_string(role), content: content}
  end

  defp normalize_message(%{role: role, content: content}) when is_binary(role) do
    %{role: role, content: content}
  end

  defp normalize_message(%{"role" => role, "content" => content}) do
    %{role: to_string(role), content: content}
  end
end
