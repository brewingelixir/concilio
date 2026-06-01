defmodule Concilio.Crypto do
  @moduledoc """
  Symmetric encryption for at-rest secrets (provider API keys today).

  AES-256-GCM with a 16-byte random IV per call and a 16-byte auth tag.
  The on-disk binary layout is `<<version::8, iv::16, tag::16, ct::binary>>`.

  The encryption key is derived from `Application.fetch_env!(:concilio,
  :concilio_secret)` (set in `config/runtime.exs`) via PBKDF2-HMAC-SHA256
  with a fixed app-level salt. We don't rotate the salt; rotating
  `CONCILIO_SECRET` rotates the key and invalidates all prior
  ciphertexts (the user must re-enter creds, which is acceptable for a
  single-user tool).
  """

  @version 1
  @salt "concilio.crypto.v1"
  @iterations 100_000
  @key_bytes 32
  @iv_bytes 16
  @tag_bytes 16

  @doc """
  Encrypts a binary into the framed ciphertext format.
  """
  @spec encrypt(binary()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, "", true)
    <<@version::8, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ct::binary>>
  end

  @doc """
  Decrypts a framed ciphertext back to the original binary, or returns
  `:error` on tag mismatch / format mismatch.
  """
  @spec decrypt(binary()) :: {:ok, binary()} | :error
  def decrypt(
        <<@version::8, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ct::binary>>
      ) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ct, "", tag, false) do
      pt when is_binary(pt) -> {:ok, pt}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def decrypt(_), do: :error

  defp key do
    secret = Application.fetch_env!(:concilio, :concilio_secret)
    :crypto.pbkdf2_hmac(:sha256, secret, @salt, @iterations, @key_bytes)
  end
end
