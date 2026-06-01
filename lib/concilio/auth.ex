defmodule Concilio.Auth do
  @moduledoc """
  Single-user auth context.

  Owns the `app_state` singleton row: the Argon2 hash of the auth token,
  a rotating session secret used to sign cookies, and a free-form `kv`
  map for app-level key/value state.

  Token generation, filesystem persistence, and the first-boot bootstrap
  flow live in the helper modules under `Concilio.Auth.*`.
  """

  import Ecto.Query, warn: false

  alias Concilio.AppState
  alias Concilio.Repo

  @singleton_id 1

  @doc """
  Returns the singleton `app_state` row, inserting an empty one if it
  does not exist yet. Idempotent.
  """
  @spec get_or_create_state() :: AppState.t()
  def get_or_create_state do
    case Repo.get(AppState, @singleton_id) do
      nil ->
        %AppState{}
        |> AppState.changeset(%{id: @singleton_id, kv: %{}})
        |> Repo.insert!()

      %AppState{} = state ->
        state
    end
  end

  @doc """
  Returns the singleton row, or `nil` if it has never been created.
  """
  @spec get_state() :: AppState.t() | nil
  def get_state, do: Repo.get(AppState, @singleton_id)

  @doc """
  Replaces the stored token hash. Used at first-boot and on
  `mix concilio.reset_token`.
  """
  @spec put_token_hash(String.t()) :: {:ok, AppState.t()} | {:error, Ecto.Changeset.t()}
  def put_token_hash(hash) when is_binary(hash) do
    get_or_create_state()
    |> AppState.changeset(%{token_hash: hash})
    |> Repo.update()
  end

  @doc """
  Generates a fresh random session secret and writes it to the singleton
  row. Used on logout (kicks all existing sessions) and at first boot
  if no secret is set.
  """
  @spec rotate_secret!() :: AppState.t()
  def rotate_secret! do
    new_secret = secret_string()

    {:ok, state} =
      get_or_create_state()
      |> AppState.changeset(%{secret: new_secret})
      |> Repo.update()

    state
  end

  @doc """
  Returns the current session secret, generating one if missing.
  """
  @spec session_secret!() :: String.t()
  def session_secret! do
    case get_or_create_state() do
      %AppState{secret: nil} -> rotate_secret!().secret
      %AppState{secret: secret} -> secret
    end
  end

  @doc """
  Set a key in the singleton's free-form `kv` map.
  """
  @spec set_kv(String.t(), term()) :: {:ok, AppState.t()} | {:error, Ecto.Changeset.t()}
  def set_kv(key, value) when is_binary(key) do
    state = get_or_create_state()
    new_kv = Map.put(state.kv, key, value)

    state
    |> AppState.changeset(%{kv: new_kv})
    |> Repo.update()
  end

  defp secret_string do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
