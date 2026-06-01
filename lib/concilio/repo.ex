defmodule Concilio.Repo do
  @moduledoc """
  Ecto repository.

  Storage backend is chosen at compile time via the `CONCILIO_DB`
  environment variable:

      CONCILIO_DB=sqlite     # default — `Ecto.Adapters.SQLite3`
      CONCILIO_DB=postgres   # opt-in — `Ecto.Adapters.Postgres`

  This is a *compile-time* switch on purpose. Storage choice is a
  durable decision (data layout differs between adapters); it should
  not flip at runtime. Switching requires a `mix do clean, deps.compile`
  cycle plus a manual data migration.
  """

  @adapter (case System.get_env("CONCILIO_DB", "sqlite") do
              "postgres" ->
                Ecto.Adapters.Postgres

              "sqlite" ->
                Ecto.Adapters.SQLite3

              other ->
                raise "invalid CONCILIO_DB=#{inspect(other)}, expected \"sqlite\" or \"postgres\""
            end)

  use Ecto.Repo,
    otp_app: :concilio,
    adapter: @adapter

  @doc """
  Returns the adapter module compiled into the Repo. Useful for
  config files that need to branch on the chosen storage backend
  (e.g. Oban engine selection).
  """
  @spec adapter() :: module()
  def adapter, do: @adapter
end
