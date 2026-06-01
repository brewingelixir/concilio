defmodule Concilio.Providers.Bootstrapper do
  @moduledoc """
  Boot-time task that reconciles the bundled provider catalog into the
  `provider_models` table. Disabled in :test.
  """

  use Task, restart: :transient

  require Logger

  alias Concilio.Providers
  alias Concilio.Providers.Runtime

  @doc false
  def start_link(_opts), do: Task.start_link(__MODULE__, :run, [])

  @spec run() :: :ok
  def run do
    %{inserted: ins, deprecated: dep} = Providers.sync_bundled_catalog!()

    if ins > 0 or dep > 0 do
      Logger.info("Provider catalog reconciled: +#{ins} inserted, #{dep} deprecated")
    end

    list = Runtime.refresh!()
    Logger.info("Pushed #{length(list)} provider config(s) into council_ex env")

    :ok
  end
end
