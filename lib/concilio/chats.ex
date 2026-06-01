defmodule Concilio.Chats do
  @moduledoc """
  Conversations + messages context. M4 surface; council-summon turn
  flow lives here too (it inserts the assistant `message` row with
  `run_id` populated).
  """

  import Ecto.Query, warn: false

  alias Concilio.Chats.{Conversation, Message}
  alias Concilio.Repo

  # ── Conversations ───────────────────────────────────────────────────

  @doc """
  Active (non-deleted) conversations ordered by recent activity.
  """
  @spec list_conversations(keyword()) :: [Conversation.t()]
  def list_conversations(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Repo.all(
      from c in Conversation,
        where: is_nil(c.deleted_at),
        order_by: [desc_nulls_last: c.pinned_at, desc: c.updated_at],
        limit: ^limit
    )
  end

  @doc """
  Fetch a single conversation by id.
  """
  @spec get_conversation!(Ecto.UUID.t()) :: Conversation.t()
  def get_conversation!(id), do: Repo.get!(Conversation, id)

  @doc """
  Create a new conversation. Title defaults to nil; an Oban job will
  auto-title at M7.
  """
  @spec create_conversation(map()) :: {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def create_conversation(attrs \\ %{}) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_conversation(Conversation.t(), map()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def update_conversation(%Conversation{} = conv, attrs) do
    conv
    |> Conversation.changeset(attrs)
    |> Repo.update()
  end

  @spec soft_delete_conversation(Conversation.t()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def soft_delete_conversation(%Conversation{} = conv) do
    conv
    |> Conversation.changeset(%{deleted_at: DateTime.utc_now()})
    |> Repo.update()
  end

  # ── Messages ────────────────────────────────────────────────────────

  @doc """
  Returns messages for a conversation in chronological order.
  """
  @spec list_messages(Ecto.UUID.t(), keyword()) :: [Message.t()]
  def list_messages(conversation_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    Repo.all(
      from m in Message,
        where: m.conversation_id == ^conversation_id,
        order_by: [asc: m.inserted_at],
        limit: ^limit,
        preload: [:run, :template]
    )
  end

  @doc """
  Returns the conversation id for a given run id, or nil if no message
  references the run (e.g. runs started outside the chat flow).
  """
  @spec conversation_id_for_run(Ecto.UUID.t()) :: Ecto.UUID.t() | nil
  def conversation_id_for_run(run_id) when is_binary(run_id) do
    Repo.one(
      from m in Message,
        where: m.run_id == ^run_id,
        select: m.conversation_id,
        limit: 1
    )
  end

  @doc """
  Insert a user `messages` row.
  """
  @spec append_user_message(Conversation.t(), String.t()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def append_user_message(%Conversation{id: cid}, content) when is_binary(content) do
    %Message{}
    |> Message.changeset(%{
      conversation_id: cid,
      role: :user,
      content: content
    })
    |> Repo.insert()
  end

  @doc """
  Insert a plain (single-model) assistant message.
  """
  @spec append_plain_assistant(Conversation.t(), String.t(), String.t()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def append_plain_assistant(%Conversation{id: cid}, model_used, content)
      when is_binary(model_used) and is_binary(content) do
    %Message{}
    |> Message.changeset(%{
      conversation_id: cid,
      role: :assistant,
      content: content,
      model_used: model_used,
      status: :ok
    })
    |> Repo.insert()
  end

  @doc """
  Insert a plain assistant placeholder with `status: :pending`. The
  supervised plain-completion worker fills it in later via
  `complete_plain_assistant/2` or `fail_plain_assistant/2`.
  """
  @spec start_plain_assistant(Conversation.t(), String.t()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def start_plain_assistant(%Conversation{id: cid}, model_used)
      when is_binary(model_used) do
    %Message{}
    |> Message.changeset(%{
      conversation_id: cid,
      role: :assistant,
      content: "",
      model_used: model_used,
      status: :pending
    })
    |> Repo.insert()
  end

  @spec complete_plain_assistant(Message.t(), String.t()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def complete_plain_assistant(%Message{} = msg, content) when is_binary(content) do
    msg
    |> Message.changeset(%{content: content, status: :ok})
    |> Repo.update()
  end

  @spec fail_plain_assistant(Message.t(), String.t()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def fail_plain_assistant(%Message{} = msg, error_text) when is_binary(error_text) do
    msg
    |> Message.changeset(%{content: error_text, status: :error})
    |> Repo.update()
  end

  @doc """
  Insert a council assistant message linked to a run.
  """
  @spec append_council_assistant(Conversation.t(), map()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def append_council_assistant(%Conversation{id: cid}, attrs) do
    %Message{}
    |> Message.changeset(
      Map.merge(attrs, %{
        conversation_id: cid,
        role: :assistant,
        content: ""
      })
    )
    |> Repo.insert()
  end

  @doc """
  Render-side helper: serialize prior messages into a context block
  that members can consume as input. Format kept deliberately plain
  so any provider's chat-completion model handles it well.
  """
  @spec build_history_input([Message.t()], String.t()) :: String.t()
  def build_history_input(prior, latest_user) when is_list(prior) and is_binary(latest_user) do
    history =
      prior
      |> Enum.map(fn
        %Message{role: :user, content: c} ->
          "User: #{c}"

        %Message{role: :assistant, content: c} when c != "" ->
          "Assistant: #{c}"

        %Message{role: :assistant, run_id: rid} when is_binary(rid) ->
          "Assistant: (council reply)"

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    if history == "" do
      "User: #{latest_user}"
    else
      "#{history}\nUser: #{latest_user}"
    end
  end
end
