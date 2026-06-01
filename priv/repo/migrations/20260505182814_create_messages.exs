defmodule Concilio.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :role, :string, null: false
      add :content, :text, null: false, default: ""

      # Plain-turn fields
      add :model_used, :string

      # Council-turn fields
      add :run_id, references(:runs, type: :binary_id, on_delete: :nilify_all)
      add :template_id, references(:council_templates, type: :binary_id, on_delete: :nilify_all)

      add :template_version_id,
          references(:council_template_versions, type: :binary_id, on_delete: :nilify_all)

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:messages, [:conversation_id, :inserted_at])
    create index(:messages, [:run_id])
    create index(:messages, [:role])
  end
end
