defmodule Concilio.Providers.Model do
  @moduledoc """
  One model entry per (provider, model_id). May come from the bundled
  catalog (`source: :bundled`), the user (`:user_added`), an OpenRouter
  live catalog refresh (`:live_catalog`), or a local Ollama probe
  (`:local_detected`). `in_working_set` is the user's curated subset
  surfaced in council builders + chat pickers.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Concilio.Providers.Setting

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @sources [:bundled, :user_added, :live_catalog, :local_detected]
  @test_statuses [:ok, :error]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          provider: atom() | nil,
          model_id: String.t() | nil,
          in_working_set: boolean(),
          source: atom() | nil,
          metadata_json: map(),
          last_test_at: DateTime.t() | nil,
          last_test_status: atom() | nil,
          last_test_latency_ms: integer() | nil,
          last_test_error: String.t() | nil,
          deprecated_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "provider_models" do
    field :provider, Ecto.Enum, values: Setting.providers()
    field :model_id, :string
    field :in_working_set, :boolean, default: false
    field :source, Ecto.Enum, values: @sources, default: :bundled
    field :metadata_json, :map, default: %{}
    field :last_test_at, :utc_datetime_usec
    field :last_test_status, Ecto.Enum, values: @test_statuses
    field :last_test_latency_ms, :integer
    field :last_test_error, :string
    field :deprecated_at, :utc_datetime_usec

    timestamps()
  end

  @doc false
  def changeset(model, attrs) do
    model
    |> cast(attrs, [
      :provider,
      :model_id,
      :in_working_set,
      :source,
      :metadata_json,
      :last_test_at,
      :last_test_status,
      :last_test_latency_ms,
      :last_test_error,
      :deprecated_at
    ])
    |> validate_required([:provider, :model_id, :source])
    |> unique_constraint([:provider, :model_id])
  end

  @spec sources() :: [atom()]
  def sources, do: @sources
end
