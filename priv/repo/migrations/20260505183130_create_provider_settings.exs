defmodule Concilio.Repo.Migrations.CreateProviderSettings do
  use Ecto.Migration

  def change do
    create table(:provider_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :enabled, :boolean, null: false, default: false
      add :encrypted_credentials, :binary
      add :endpoint_override, :string
      add :options_json, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:provider_settings, [:provider])
  end
end
