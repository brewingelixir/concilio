defmodule Concilio.Auth.Token do
  @moduledoc """
  Concilio's auth token: a 32-byte random value, base64url-encoded
  (`Base.url_encode64/2` with `padding: false`).

  - `generate/0` returns a fresh token.
  - `hash/1` produces an Argon2 hash for storage in `app_state.token_hash`.
  - `verify/2` checks a candidate token against a stored hash.

  Tokens are also written to disk by `Concilio.Auth.TokenStore` so the
  user can copy-paste them into the login form on a fresh machine.
  """

  @doc """
  Generates a new auth token.
  """
  @spec generate() :: String.t()
  def generate do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Hashes a token using Argon2 for at-rest storage.
  """
  @spec hash(String.t()) :: String.t()
  def hash(token) when is_binary(token), do: Argon2.hash_pwd_salt(token)

  @doc """
  Verifies a candidate token against a stored Argon2 hash.

  Returns `true` on match, `false` otherwise. Constant-time on hash
  comparison; the no-user dummy verify keeps timing identical when the
  hash is missing (e.g. before first boot).
  """
  @spec verify(nil | String.t(), nil | String.t()) :: boolean()
  def verify(_token, nil) do
    Argon2.no_user_verify()
    false
  end

  def verify(nil, _hash), do: false

  def verify(token, hash) when is_binary(token) and is_binary(hash) do
    Argon2.verify_pass(token, hash)
  end
end
