defmodule Concilio.Chats.PlainCompletionWorker do
  @moduledoc """
  Runs a plain (single-model) chat completion under the
  `Concilio.Chats.PlainCompletion.Supervisor` `Task.Supervisor`, so the
  HTTP call survives LV socket close / page reload.

  Lifecycle:

  1. LV inserts the assistant placeholder via
     `Concilio.Chats.start_plain_assistant/2` (status `:pending`).
  2. LV calls `start/4` here with the placeholder's `message_id`,
     provider, model, and the prebuilt history list.
  3. This module supervises the call. On success it stamps the message
     with the response content + status `:ok`; on failure it stores an
     error string + status `:error`. Either way it broadcasts on the
     conversation topic so any mounted LV (including a freshly
     reloaded one) refreshes.

  We deliberately use `Task.Supervisor.start_child` (not `start_async`
  in the LV) so the LV can die at any time without aborting the call.
  """

  require Logger

  alias Concilio.Chats
  alias Concilio.Chats.{Completion, Message}
  alias Concilio.Repo

  @sup Concilio.Chats.PlainCompletion.Supervisor

  @doc """
  Spawn a supervised task that completes the plain chat request and
  updates the placeholder message row. Returns `{:ok, pid}`.
  """
  @spec start(String.t(), atom(), String.t(), [map()]) ::
          {:ok, pid()} | {:error, term()}
  def start(message_id, provider, model, history)
      when is_binary(message_id) and is_atom(provider) and is_binary(model) and is_list(history) do
    Task.Supervisor.start_child(@sup, fn ->
      run_and_record(message_id, provider, model, history)
    end)
  end

  defp run_and_record(message_id, provider, model, history) do
    case Completion.run(provider, model, history) do
      {:ok, content} ->
        finalize(message_id, fn msg -> Chats.complete_plain_assistant(msg, content) end)

      {:error, reason} ->
        Logger.error(
          "plain_completion provider error: provider=#{inspect(provider)} model=#{inspect(model)} reason=#{inspect(reason)} message_id=#{message_id}"
        )

        finalize(message_id, fn msg ->
          Chats.fail_plain_assistant(msg, format_reason(reason))
        end)
    end
  rescue
    error ->
      Logger.error(
        "plain_completion crashed: message_id=#{message_id} error=#{Exception.format(:error, error, __STACKTRACE__)}"
      )

      finalize(message_id, fn msg ->
        Chats.fail_plain_assistant(msg, "Completion crashed: #{Exception.message(error)}")
      end)
  end

  defp finalize(message_id, update_fun) do
    case Repo.get(Message, message_id) do
      nil ->
        Logger.warning("plain_completion finalize: message #{message_id} not found")
        :ok

      %Message{conversation_id: cid} = msg ->
        case update_fun.(msg) do
          {:ok, _updated} ->
            broadcast(cid, message_id)

          {:error, changeset} ->
            Logger.error(
              "plain_completion finalize failed: message_id=#{message_id} changeset=#{inspect(changeset.errors)}"
            )
        end
    end
  end

  defp broadcast(conversation_id, message_id) do
    Phoenix.PubSub.broadcast(
      Concilio.PubSub,
      "concilio:chat:" <> conversation_id,
      {:plain_message_updated, message_id}
    )
  end

  defp format_reason(%CouncilEx.Error{message: msg}) when is_binary(msg), do: msg

  defp format_reason(%CouncilEx.Error{reason: {:http, status, body}}),
    do: "HTTP #{status}: #{truncate(body, 400)}"

  defp format_reason(%CouncilEx.Error{reason: reason}), do: inspect(reason)
  defp format_reason(%{message: msg}) when is_binary(msg), do: msg
  defp format_reason({:provider_not_configured, p}), do: "provider #{p} not configured"
  defp format_reason(reason), do: inspect(reason)

  defp truncate(s, max) when is_binary(s) and byte_size(s) > max,
    do: binary_part(s, 0, max) <> "…"

  defp truncate(s, _), do: s
end
