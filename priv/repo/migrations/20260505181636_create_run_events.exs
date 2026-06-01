defmodule Concilio.Repo.Migrations.CreateRunEvents do
  use Ecto.Migration

  def change do
    create table(:run_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id,
          references(:runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :idx, :integer, null: false
      add :type, :string, null: false
      add :payload_json, :map, null: false, default: %{}
      add :payload_version, :integer, null: false, default: 1

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:run_events, [:run_id, :idx])
    create index(:run_events, [:type])
  end
end
