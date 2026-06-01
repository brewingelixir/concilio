defmodule Concilio.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    maybe_auto_migrate()

    children =
      [
        ConcilioWeb.Telemetry,
        Concilio.Repo,
        {DNSCluster, query: Application.get_env(:concilio, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Concilio.PubSub},
        {Oban, Application.fetch_env!(:concilio, Oban)},
        {DynamicSupervisor, name: Concilio.RunRecorder.Supervisor, strategy: :one_for_one},
        {CouncilEx.Supervisor, name: Concilio.RunSupervisor},
        {Task.Supervisor, name: Concilio.Chats.PlainCompletion.Supervisor},
        Concilio.Auth.RateLimiter
      ] ++
        settings_child() ++
        bootstrapper_children() ++
        [ConcilioWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Concilio.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ConcilioWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp bootstrapper_children do
    auth =
      if Application.get_env(:concilio, :start_auth_bootstrapper?, true),
        do: [Concilio.Auth.Bootstrapper],
        else: []

    councils =
      if Application.get_env(:concilio, :start_councils_bootstrapper?, true),
        do: [Concilio.Councils.Bootstrapper],
        else: []

    providers =
      if Application.get_env(:concilio, :start_providers_bootstrapper?, true),
        do: [Concilio.Providers.Bootstrapper],
        else: []

    chat_recovery =
      if Application.get_env(:concilio, :start_chat_recovery?, true),
        do: [Concilio.Chats.Recovery],
        else: []

    auth ++ councils ++ providers ++ chat_recovery
  end

  defp settings_child do
    if Application.get_env(:concilio, :start_settings?, true),
      do: [Concilio.Settings],
      else: []
  end

  # In prod / release builds, run pending migrations before the
  # endpoint comes up. If migrations fail we log loudly and stash
  # the error in app env so the web layer can surface it on first
  # request instead of leaving the user with an opaque 500. Gated
  # on `:auto_migrate?` so dev/test (which use `ecto.create` + the
  # `mix test` alias) keep their existing flow.
  defp maybe_auto_migrate do
    if Application.get_env(:concilio, :auto_migrate?, false) do
      case Concilio.Release.migrate() do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("""
          [Concilio] database migrations failed during boot.
          The application will start but most requests will fail until this is resolved.
          Reason: #{inspect(reason)}
          """)

          Application.put_env(:concilio, :migration_error, reason)
      end
    end
  end
end
