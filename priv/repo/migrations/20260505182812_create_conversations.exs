defmodule Concilio.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string
      add :default_responder_kind, :string, null: false, default: "model"
      add :default_model, :string

      add :default_template_id,
          references(:council_templates, type: :binary_id, on_delete: :nilify_all)

      add :pinned_at, :utc_datetime_usec
      add :archived_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversations, [:archived_at])
    create index(:conversations, [:deleted_at])
    create index(:conversations, [:updated_at])
  end
end
