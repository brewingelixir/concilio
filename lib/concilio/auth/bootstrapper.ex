defmodule Concilio.Auth.Bootstrapper do
  @moduledoc """
  One-shot startup task that ensures the `app_state` singleton row
  exists and seeds the auth token + session secret on a fresh boot.

  Behavior:

  1. If no `app_state` row exists, insert one (`id = 1`).
  2. If `app_state.secret` is missing, generate one.
  3. If `app_state.token_hash` is missing **or** the on-disk token
     file is missing **or** the file's contents don't match the
     stored hash, generate a fresh token, write it to
     `<data-dir>/auth_token` (mode 0600), and store its Argon2 hash.
     Print the token to stdout exactly once.
  4. Otherwise, do nothing.

  The file ↔ hash mismatch case happens when two environments share
  a data dir (e.g. running prod and dev pointed at `~/.concilio`),
  or when a backup restores the DB but not the file (or vice versa).
  Regenerating self-heals — the user just sees a fresh token printed
  on the next boot.

  Idempotent across restarts: a healthy install boots silently.
  """

  use Task, restart: :transient

  require Logger

  alias Concilio.Auth
  alias Concilio.Auth.Token
  alias Concilio.Auth.TokenStore

  @doc false
  def start_link(_opts) do
    Task.start_link(__MODULE__, :run, [])
  end

  @doc """
  Idempotent bootstrap. Safe to call multiple times.
  """
  @spec run() :: :ok
  def run do
    state = Auth.get_or_create_state()

    if is_nil(state.secret), do: Auth.rotate_secret!()

    if needs_new_token?(state), do: regenerate_token!()

    :ok
  end

  # True when the DB hash is missing, the on-disk token is missing,
  # or the on-disk token doesn't match the DB hash. The match check
  # protects against the case where the data dir has drifted away
  # from the DB (e.g. switching envs that share `~/.concilio`).
  defp needs_new_token?(state) do
    cond do
      is_nil(state.token_hash) ->
        true

      true ->
        case TokenStore.read() do
          :error -> true
          {:ok, token} -> not Token.verify(token, state.token_hash)
        end
    end
  end

  defp regenerate_token! do
    token = Token.generate()
    hash = Token.hash(token)

    TokenStore.write!(token)
    {:ok, _state} = Auth.put_token_hash(hash)

    if Application.get_env(:concilio, :print_token_on_boot?, true) do
      announce(token, TokenStore.file_path())
    end

    :ok
  end

  defp announce(token, path) do
    banner = """

    =============================================================
      Concilio auth token (paste this on the login page):

        #{token}

      Also written to: #{path} (mode 0600)
      Reset with: mix concilio.reset_token
    =============================================================
    """

    IO.puts(banner)
    Logger.info("Generated new Concilio auth token at #{path}")
  end
end
