defmodule Concilio.Repo.Migrations.CreateCouncilTemplates do
  use Ecto.Migration

  def change do
    create table(:council_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :source_module, :string
      add :current_version_id, :binary_id
      add :archived_at, :utc_datetime_usec
      add :cloned_from_template_id, :binary_id
      add :cloned_from_version_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:council_templates, [:slug])
    create index(:council_templates, [:kind])
    create index(:council_templates, [:archived_at])
  end
end
