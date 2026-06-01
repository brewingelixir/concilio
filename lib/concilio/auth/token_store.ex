defmodule Concilio.Auth.TokenStore do
  @moduledoc """
  Reads / writes the Concilio auth token to disk.

  The token file lives inside the application data dir, which is
  per-environment (see `runtime.exs`):

    * dev (`mix phx.server`)  → `priv/.dev/auth_token`
    * test                    → `$TMPDIR/concilio_test_*/auth_token`
    * prod / menubar app      → `~/.concilio/auth_token`

  Don't assume `~/.concilio` — that's only the prod path. The dir
  resolution chain is:

  1. `config :concilio, :auth_token_path` — full file path override
     (used by tests).
  2. `config :concilio, :data_dir` — runtime.exs always publishes the
     resolved per-env dir here; the token sits beside `concilio.db`.
  3. `$CONCILIO_DATA_DIR` env var — same env var the SQLite runtime
     uses, in case `:data_dir` was not configured (e.g. Postgres
     prod where the data dir convention still applies for the
     token file).
  4. `~/.concilio` — last-resort fallback.

  The menubar (Tauri) app needs no manual login: the bootstrapper
  generates + persists the token on first boot, and the shell opens
  the browser at `?token=<...>`. Manual `mix concilio.reset_token` +
  paste is a dev / recovery affordance, not the normal path.

  The file is created mode `0600` inside a `0700` directory so other
  users on the box can't see it. It holds the raw token (not the
  Argon2 hash) so the user can copy-paste it into the login form;
  the hash of record always lives in `app_state.token_hash`.
  """

  @dir_mode 0o700
  @file_mode 0o600

  @doc """
  Writes the token to the on-disk path. Creates the directory if
  needed and tightens permissions on both the dir and file.
  """
  @spec write!(String.t()) :: :ok
  def write!(token) when is_binary(token) do
    dir = dir_path()
    file = file_path()

    File.mkdir_p!(dir)
    File.chmod!(dir, @dir_mode)
    File.write!(file, token)
    File.chmod!(file, @file_mode)
    :ok
  end

  @doc """
  Returns `{:ok, token}` if the file exists and is readable, `:error`
  otherwise.
  """
  @spec read() :: {:ok, String.t()} | :error
  def read do
    case File.read(file_path()) do
      {:ok, content} -> {:ok, String.trim(content)}
      {:error, _reason} -> :error
    end
  end

  @doc """
  Removes the on-disk token, if any.
  """
  @spec delete() :: :ok
  def delete do
    _ = File.rm(file_path())
    :ok
  end

  @doc """
  Absolute path to the token file. Configurable via
  `config :concilio, :auth_token_path` for tests.
  """
  @spec file_path() :: Path.t()
  def file_path do
    case Application.get_env(:concilio, :auth_token_path) do
      nil -> Path.join(dir_path(), "auth_token")
      path when is_binary(path) -> path
    end
  end

  @doc """
  Absolute path to the parent directory.
  """
  @spec dir_path() :: Path.t()
  def dir_path do
    case Application.get_env(:concilio, :auth_token_path) do
      path when is_binary(path) -> Path.dirname(path)
      _ -> resolve_data_dir()
    end
  end

  defp resolve_data_dir do
    cond do
      dir = Application.get_env(:concilio, :data_dir) ->
        dir

      dir = System.get_env("CONCILIO_DATA_DIR") ->
        dir

      true ->
        Path.join(home_dir(), ".concilio")
    end
  end

  defp home_dir do
    case System.user_home() do
      nil -> raise "no $HOME set; cannot locate ~/.concilio"
      home -> home
    end
  end
end
