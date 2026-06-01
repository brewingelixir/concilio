defmodule Concilio.CryptoTest do
  use ExUnit.Case, async: true

  alias Concilio.Crypto

  setup do
    Application.put_env(
      :concilio,
      :concilio_secret,
      "unit-test-secret-#{System.unique_integer()}"
    )

    on_exit(fn ->
      Application.put_env(
        :concilio,
        :concilio_secret,
        "dev-only-not-secret-replace-with-CONCILIO_SECRET-in-production"
      )
    end)

    :ok
  end

  test "round-trips a binary" do
    assert {:ok, "hello"} = Crypto.decrypt(Crypto.encrypt("hello"))
    assert {:ok, ""} = Crypto.decrypt(Crypto.encrypt(""))
  end

  test "produces a different ciphertext per call (random IV)" do
    a = Crypto.encrypt("same-input")
    b = Crypto.encrypt("same-input")

    refute a == b
    assert {:ok, "same-input"} = Crypto.decrypt(a)
    assert {:ok, "same-input"} = Crypto.decrypt(b)
  end

  test "tampered ciphertext fails to decrypt" do
    ct = Crypto.encrypt("secret")
    # Flip the low bit of the last byte by position. (The previous
    # :binary.replace approach searched by byte *value* and was a no-op
    # whenever the last byte was already 0x00 — a ~1/256 flake.)
    last = byte_size(ct) - 1
    <<head::binary-size(last), b>> = ct
    flipped = <<head::binary, Bitwise.bxor(b, 1)>>

    refute flipped == ct
    assert :error = Crypto.decrypt(flipped)
  end

  test "garbage input fails cleanly" do
    assert :error = Crypto.decrypt(<<0, 1, 2, 3>>)
    assert :error = Crypto.decrypt("")
  end
end
