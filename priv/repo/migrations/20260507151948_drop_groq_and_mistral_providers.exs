defmodule Concilio.Repo.Migrations.DropGroqAndMistralProviders do
  use Ecto.Migration

  @doc """
  Removes any persisted rows for the `:groq` and `:mistral` provider
  enums. The Ecto.Enum dropped those values from `Setting.@providers`,
  so leftover rows would fail to load. Runs are unaffected — runs link
  to a `template_version`, not a provider directly.
  """
  def up do
    execute("DELETE FROM provider_models WHERE provider IN ('groq', 'mistral')")
    execute("DELETE FROM provider_settings WHERE provider IN ('groq', 'mistral')")
  end

  def down do
    # No-op: we cannot resurrect deleted credentials. Re-add the
    # providers via the catalog + bootstrapper if needed.
    :ok
  end
end
