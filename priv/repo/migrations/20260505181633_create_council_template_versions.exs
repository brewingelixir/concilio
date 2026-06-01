defmodule Concilio.Repo.Migrations.CreateCouncilTemplateVersions do
  use Ecto.Migration

  def change do
    create table(:council_template_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :template_id,
          references(:council_templates, type: :binary_id, on_delete: :delete_all),
          null: false

      add :version, :integer, null: false
      add :spec_json, :map, null: false, default: %{}
      add :payload_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:council_template_versions, [:template_id, :version])

    # Originally backfilled a FK on
    # `council_templates.current_version_id`. SQLite does not support
    # ALTER COLUMN, so the column stays a bare `:binary_id`. Versions
    # are immutable and never deleted in normal operation
    # (`Concilio.Councils` archives templates instead), so the
    # dropped `on_delete: :nilify_all` behavior is a non-issue. The
    # drop is a no-op for the Postgres path too.
  end
end
