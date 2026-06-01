defmodule Concilio.Auth.TokenTest do
  use ExUnit.Case, async: true

  alias Concilio.Auth.Token

  describe "generate/0" do
    test "returns a base64url-encoded 32-byte token" do
      token = Token.generate()
      assert is_binary(token)

      decoded = Base.url_decode64!(token, padding: false)
      assert byte_size(decoded) == 32
    end

    test "is not predictable across calls" do
      tokens = for _ <- 1..50, do: Token.generate()
      assert tokens |> Enum.uniq() |> length() == 50
    end
  end

  describe "hash/1 + verify/2" do
    test "round-trips a generated token" do
      token = Token.generate()
      hash = Token.hash(token)

      assert Token.verify(token, hash)
      refute Token.verify(token <> "x", hash)
    end

    test "verify/2 returns false on missing inputs" do
      refute Token.verify(nil, "anything")
      refute Token.verify("anything", nil)
    end
  end
end
