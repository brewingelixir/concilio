defmodule Concilio.Councils.Template do
  @moduledoc """
  A reusable council spec. `:static` templates are backed by a Concilio
  module discovered at compile/boot time; `:dynamic` templates are
  authored via the builder UI and edited as immutable versions.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Concilio.Councils.TemplateVersion

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @kinds [:static, :dynamic]

  @type kind :: :static | :dynamic

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          kind: kind() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          description: String.t() | nil,
          source_module: String.t() | nil,
          current_version_id: Ecto.UUID.t() | nil,
          archived_at: DateTime.t() | nil,
          samples: [map()],
          cloned_from_template_id: Ecto.UUID.t() | nil,
          cloned_from_version_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          versions: [TemplateVersion.t()] | Ecto.Association.NotLoaded.t(),
          current_version: TemplateVersion.t() | Ecto.Association.NotLoaded.t() | nil
        }

  schema "council_templates" do
    field :kind, Ecto.Enum, values: @kinds
    field :name, :string
    field :slug, :string
    field :description, :string
    field :source_module, :string
    field :archived_at, :utc_datetime_usec
    field :samples, {:array, :map}, default: []
    field :cloned_from_template_id, Ecto.UUID
    field :cloned_from_version_id, Ecto.UUID

    has_many :versions, TemplateVersion, foreign_key: :template_id
    belongs_to :current_version, TemplateVersion, type: :binary_id

    timestamps()
  end

  @doc false
  def changeset(template, attrs) do
    template
    |> cast(attrs, [
      :kind,
      :name,
      :slug,
      :description,
      :source_module,
      :current_version_id,
      :archived_at,
      :samples,
      :cloned_from_template_id,
      :cloned_from_version_id
    ])
    |> validate_required([:kind, :name, :slug])
    |> validate_inclusion(:kind, @kinds)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9_-]*$/,
      message: "must be lowercase, alphanumeric, dashes/underscores"
    )
    |> unique_constraint(:slug)
  end

  @spec kinds() :: [kind()]
  def kinds, do: @kinds
end
