defmodule Concilio.Repo.Migrations.AddSamplesToCouncilTemplates do
  use Ecto.Migration

  def change do
    alter table(:council_templates) do
      add :samples, {:array, :map}, null: false, default: []
    end
  end
end
