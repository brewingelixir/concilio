defmodule Concilio.Chats.Message do
  @moduledoc """
  One turn in a conversation. Two shapes per the decisions log:

  - **Plain** — `role: :user | :assistant`, `run_id == nil`,
    `model_used` set on assistant, `content` holds rendered text.
  - **Council** — `role: :assistant`, `run_id` set (FK to runs),
    `template_id` + `template_version_id` set; `content` is empty
    (the renderer reads `runs.result_json`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Concilio.Chats.Conversation
  alias Concilio.Councils.{Template, TemplateVersion}
  alias Concilio.Runs.Run

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles [:user, :assistant, :system]
  @statuses [:pending, :ok, :error]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          conversation_id: Ecto.UUID.t() | nil,
          role: :user | :assistant | :system | nil,
          content: String.t(),
          model_used: String.t() | nil,
          status: :pending | :ok | :error | nil,
          run_id: Ecto.UUID.t() | nil,
          template_id: Ecto.UUID.t() | nil,
          template_version_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "messages" do
    field :role, Ecto.Enum, values: @roles
    field :content, :string, default: ""
    field :model_used, :string
    field :status, Ecto.Enum, values: @statuses, default: :ok

    belongs_to :conversation, Conversation, type: :binary_id
    belongs_to :run, Run, type: :binary_id
    belongs_to :template, Template, type: :binary_id
    belongs_to :template_version, TemplateVersion, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :conversation_id,
      :role,
      :content,
      :model_used,
      :status,
      :run_id,
      :template_id,
      :template_version_id
    ])
    |> validate_required([:conversation_id, :role])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:status, @statuses)
  end

  @spec council_turn?(t()) :: boolean()
  def council_turn?(%__MODULE__{role: :assistant, run_id: run_id}) when is_binary(run_id),
    do: true

  def council_turn?(_), do: false

  @spec plain_turn?(t()) :: boolean()
  def plain_turn?(%__MODULE__{role: :assistant, run_id: nil}), do: true
  def plain_turn?(_), do: false

  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{status: :pending}), do: true
  def pending?(_), do: false
end
