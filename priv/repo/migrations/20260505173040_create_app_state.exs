defmodule Concilio.Repo.Migrations.CreateAppState do
  use Ecto.Migration

  def change do
    create table(:app_state, primary_key: false) do
      add :id, :integer, primary_key: true, default: 1
      add :token_hash, :string
      add :secret, :string
      add :kv, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # Originally `create constraint(:app_state, :app_state_singleton,
    # check: "id = 1")`. Dropped because SQLite does not support
    # ALTER TABLE ADD CONSTRAINT, and the singleton invariant is
    # already enforced in `Concilio.Auth`, which only ever loads /
    # upserts row id=1. The integer primary key prevents duplicate
    # rows. The drop is a no-op for the Postgres path too — same
    # invariant, just lives in app code.
  end
end
