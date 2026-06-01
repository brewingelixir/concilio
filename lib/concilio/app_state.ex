defmodule Concilio.AppState do
  @moduledoc """
  Singleton row backing single-user auth + rotating session secret +
  arbitrary key/value app state.

  The migration enforces `id = 1` via a CHECK constraint; this schema
  treats the row as a singleton. All callers should go through
  `Concilio.Auth` rather than touching the schema directly.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: integer() | nil,
          token_hash: String.t() | nil,
          secret: String.t() | nil,
          kv: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "app_state" do
    field :token_hash, :string
    field :secret, :string
    field :kv, :map, default: %{}

    timestamps()
  end

  @doc false
  def changeset(state, attrs) do
    state
    |> cast(attrs, [:id, :token_hash, :secret, :kv])
    |> validate_required([:id])
    |> validate_inclusion(:id, [1], message: "app_state is a singleton; id must be 1")
  end
end
