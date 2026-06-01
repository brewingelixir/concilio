defmodule Concilio.Councils.Bootstrapper do
  @moduledoc """
  Boot-time task that syncs bundled static council modules into the
  `council_templates` table so the index UI is non-empty out of the
  box.
  """

  use Task, restart: :transient

  require Logger

  @doc false
  def start_link(_opts) do
    Task.start_link(__MODULE__, :run, [])
  end

  @doc """
  Idempotent template sync.
  """
  @spec run() :: :ok
  def run do
    count = Concilio.Councils.sync_static_templates!() |> length()
    if count > 0, do: Logger.info("Synced #{count} static council template(s)")
    :ok
  end
end
