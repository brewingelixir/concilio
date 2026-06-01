defmodule Concilio.Repo.Migrations.CreateProviderModels do
  use Ecto.Migration

  def change do
    create table(:provider_models, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :model_id, :string, null: false
      add :in_working_set, :boolean, null: false, default: false
      add :source, :string, null: false, default: "bundled"
      add :metadata_json, :map, null: false, default: %{}
      add :last_test_at, :utc_datetime_usec
      add :last_test_status, :string
      add :last_test_latency_ms, :integer
      add :last_test_error, :text
      add :deprecated_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:provider_models, [:provider, :model_id])
    create index(:provider_models, [:provider, :in_working_set])
    create index(:provider_models, [:source])
  end
end
