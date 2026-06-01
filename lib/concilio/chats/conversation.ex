defmodule Concilio.Chats.Conversation do
  @moduledoc """
  A chat thread. Holds a default responder (single-model OR a council
  template) used when a turn doesn't specify one explicitly.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Concilio.Chats.Message
  alias Concilio.Councils.Template

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @responder_kinds [:model, :council]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          title: String.t() | nil,
          default_responder_kind: :model | :council | nil,
          default_model: String.t() | nil,
          default_template_id: Ecto.UUID.t() | nil,
          pinned_at: DateTime.t() | nil,
          archived_at: DateTime.t() | nil,
          deleted_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "conversations" do
    field :title, :string
    field :default_responder_kind, Ecto.Enum, values: @responder_kinds, default: :model
    field :default_model, :string
    field :pinned_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :default_template, Template, type: :binary_id
    has_many :messages, Message

    timestamps()
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :title,
      :default_responder_kind,
      :default_model,
      :default_template_id,
      :pinned_at,
      :archived_at,
      :deleted_at
    ])
    |> validate_inclusion(:default_responder_kind, @responder_kinds)
  end

  @spec responder_kinds() :: [atom()]
  def responder_kinds, do: @responder_kinds
end
