defmodule Concilio.Repo.Migrations.AddStatusToMessages do
  use Ecto.Migration

  # SQLite caveat: ALTER TABLE ADD COLUMN with a non-NULL default is fine
  # for a new column. We default to "ok" so historical rows treat as
  # finished, then plain-completion writers stamp ":pending" upfront and
  # update to ":ok"/":error" when the supervised worker finishes.
  def change do
    alter table(:messages) do
      add :status, :string, null: false, default: "ok"
    end

    create index(:messages, [:status])
  end
end
