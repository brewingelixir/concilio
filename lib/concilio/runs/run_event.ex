defmodule Concilio.Runs.RunEvent do
  @moduledoc """
  One persisted council_ex event. Rows are inserted in arrival order
  with a monotonically increasing per-run `idx`; replay reads them in
  that order.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Concilio.Runs.Run

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          run_id: Ecto.UUID.t() | nil,
          idx: integer() | nil,
          type: String.t() | nil,
          payload_json: map(),
          payload_version: integer(),
          inserted_at: DateTime.t() | nil,
          run: Run.t() | Ecto.Association.NotLoaded.t() | nil
        }

  schema "run_events" do
    field :idx, :integer
    field :type, :string
    field :payload_json, :map, default: %{}
    field :payload_version, :integer, default: 1

    belongs_to :run, Run, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:run_id, :idx, :type, :payload_json, :payload_version])
    |> validate_required([:run_id, :idx, :type, :payload_json])
    |> unique_constraint([:run_id, :idx])
  end
end
