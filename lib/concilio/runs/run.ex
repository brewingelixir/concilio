defmodule Concilio.Runs.Run do
  @moduledoc """
  One execution of a council template version. Persisted once at
  start-up by the caller; subsequently mutated only by
  `Concilio.RunRecorder` (single-writer rule).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Concilio.Councils.{Template, TemplateVersion}
  alias Concilio.Runs.RunEvent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses [:running, :ok, :partial, :error, :cancelled, :stuck]
  @responder_kinds [:model, :council]
  @recorder_statuses [:ok, :degraded, :stuck]

  @type status :: :running | :ok | :partial | :error | :cancelled | :stuck
  @type responder_kind :: :model | :council
  @type recorder_status :: :ok | :degraded | :stuck

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          run_id: String.t() | nil,
          template_id: Ecto.UUID.t() | nil,
          template_version_id: Ecto.UUID.t() | nil,
          parent_run_id: Ecto.UUID.t() | nil,
          input_json: map(),
          result_json: map() | nil,
          status: status() | nil,
          responder_kind: responder_kind() | nil,
          recorder_status: recorder_status() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          total_cost_cents: integer() | nil,
          total_duration_ms: integer() | nil,
          total_tokens_in: integer() | nil,
          total_tokens_out: integer() | nil,
          error_count: integer(),
          payload_version: integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "runs" do
    field :run_id, :string
    field :input_json, :map, default: %{}
    field :result_json, :map
    field :status, Ecto.Enum, values: @statuses, default: :running
    field :responder_kind, Ecto.Enum, values: @responder_kinds, default: :council
    field :recorder_status, Ecto.Enum, values: @recorder_statuses, default: :ok
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :total_cost_cents, :integer
    field :total_duration_ms, :integer
    field :total_tokens_in, :integer
    field :total_tokens_out, :integer
    field :error_count, :integer, default: 0
    field :payload_version, :integer, default: 1

    belongs_to :template, Template, type: :binary_id
    belongs_to :template_version, TemplateVersion, type: :binary_id
    belongs_to :parent_run, __MODULE__, type: :binary_id

    has_many :events, RunEvent, foreign_key: :run_id

    timestamps()
  end

  @doc false
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :run_id,
      :template_id,
      :template_version_id,
      :parent_run_id,
      :input_json,
      :status,
      :responder_kind,
      :started_at,
      :payload_version
    ])
    |> validate_required([:run_id, :template_id, :template_version_id, :input_json, :started_at])
    |> unique_constraint(:run_id)
  end

  @doc false
  def update_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :result_json,
      :status,
      :recorder_status,
      :finished_at,
      :total_cost_cents,
      :total_duration_ms,
      :total_tokens_in,
      :total_tokens_out,
      :error_count
    ])
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec terminal?(status()) :: boolean()
  def terminal?(status), do: status in [:ok, :partial, :error, :cancelled, :stuck]
end
