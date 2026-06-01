defmodule Concilio.Release do
  @moduledoc """
  Release-time tasks. Designed to be invoked from a Tauri-wrapped
  binary or `mix release` artifact via:

      bin/concilio eval "Concilio.Release.migrate()"

  In Concilio's distribution model the SQLite file lives at
  `$CONCILIO_DATA_DIR/concilio.db` (default `~/.concilio/concilio.db`)
  and migrations are run automatically by `Concilio.Application` on
  prod boot — so end users typically never invoke these directly.
  They are kept callable for ops, debugging, and Postgres deploys
  where auto-migrate may be disabled.
  """

  @app :concilio

  @doc """
  Runs all pending Ecto migrations against `Concilio.Repo`.

  Returns `:ok` on success or `{:error, reason}` on failure. The
  caller decides whether to halt boot or surface the failure in the
  UI.
  """
  @spec migrate() :: :ok | {:error, term()}
  def migrate do
    load_app()

    Enum.each(repos(), fn repo ->
      ensure_data_dir!(repo)

      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end)

    :ok
  rescue
    error ->
      {:error, error}
  end

  @doc """
  Rolls back to the given migration version.
  """
  @spec rollback(module(), integer()) :: :ok | {:error, term()}
  def rollback(repo, version) do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  rescue
    error -> {:error, error}
  end

  @doc """
  Generates a fresh auth token, stores its Argon2 hash in
  `app_state.token_hash`, rotates the rotating session secret
  (kicks every active cookie), and writes the new token to
  `<data-dir>/auth_token` (mode 0600). Returns the plaintext token
  string so the caller can display or copy it.

  Designed to be invoked from a packaged binary without `mix`:

      bin/app eval "Concilio.Release.reset_token() |> IO.puts()"

  Same effect as the dev-only `mix concilio.reset_token`, but works
  post-install. Future tray-menu / Settings-page wiring will
  delegate here.
  """
  @spec reset_token() :: String.t()
  def reset_token do
    ensure_app_started!()

    token = Concilio.Auth.Token.generate()
    hash = Concilio.Auth.Token.hash(token)

    {:ok, _state} = Concilio.Auth.put_token_hash(hash)
    _ = Concilio.Auth.rotate_secret!()
    Concilio.Auth.TokenStore.write!(token)

    token
  end

  defp ensure_app_started! do
    {:ok, _} = Application.ensure_all_started(@app)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  # Ensures the parent dir of the SQLite file exists. No-op for
  # Postgres (path config absent) or `:memory:`.
  defp ensure_data_dir!(repo) do
    case Application.get_env(@app, repo)[:database] do
      path when is_binary(path) ->
        path |> Path.dirname() |> File.mkdir_p!()

      _ ->
        :ok
    end
  end
end
