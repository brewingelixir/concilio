defmodule Concilio.Councils.TemplateVersion do
  @moduledoc """
  Immutable spec snapshot for a council template. Editing a dynamic
  template creates a new version row; existing runs stay pinned to the
  version they ran under so historical replays remain reproducible.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Concilio.Councils.Template

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          template_id: Ecto.UUID.t() | nil,
          version: integer() | nil,
          spec_json: map(),
          payload_version: integer(),
          inserted_at: DateTime.t() | nil,
          template: Template.t() | Ecto.Association.NotLoaded.t() | nil
        }

  schema "council_template_versions" do
    field :version, :integer
    field :spec_json, :map, default: %{}
    field :payload_version, :integer, default: 1

    belongs_to :template, Template, type: :binary_id

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(version, attrs) do
    version
    |> cast(attrs, [:template_id, :version, :spec_json, :payload_version])
    |> validate_required([:template_id, :version, :spec_json])
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint([:template_id, :version])
  end
end
