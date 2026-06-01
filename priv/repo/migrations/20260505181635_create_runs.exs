defmodule Concilio.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    create table(:runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The string run_id assigned by CouncilEx.Runner.RunState.new/1.
      # Indexed for replay subscription lookups.
      add :run_id, :string, null: false

      add :template_id,
          references(:council_templates, type: :binary_id, on_delete: :restrict),
          null: false

      add :template_version_id,
          references(:council_template_versions, type: :binary_id, on_delete: :restrict),
          null: false

      add :parent_run_id,
          references(:runs, type: :binary_id, on_delete: :nilify_all)

      add :input_json, :map, null: false, default: %{}
      add :result_json, :map
      add :status, :string, null: false, default: "running"

      add :responder_kind, :string, null: false, default: "council"
      add :recorder_status, :string, null: false, default: "ok"

      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec

      add :total_cost_cents, :integer
      add :total_duration_ms, :integer
      add :total_tokens_in, :integer
      add :total_tokens_out, :integer
      add :error_count, :integer, null: false, default: 0
      add :payload_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runs, [:run_id])
    create index(:runs, [:template_id, :inserted_at])
    create index(:runs, [:template_version_id])
    create index(:runs, [:parent_run_id])
    create index(:runs, [:status])
    create index(:runs, [:started_at])
  end
end
