defmodule Concilio.Repo.Migrations.AddDescriptionToCouncilTemplates do
  use Ecto.Migration

  def change do
    alter table(:council_templates) do
      add :description, :text
    end
  end
end
