defmodule Concilio.Auth.TokenStoreTest do
  use ExUnit.Case, async: true

  alias Concilio.Auth.TokenStore

  setup do
    tmp =
      System.tmp_dir!() |> Path.join("concilio-tokenstore-#{System.unique_integer([:positive])}")

    token_file = Path.join(tmp, "auth_token")

    Application.put_env(:concilio, :auth_token_path, token_file)
    on_exit(fn -> Application.delete_env(:concilio, :auth_token_path) end)
    on_exit(fn -> File.rm_rf!(tmp) end)

    %{tmp: tmp, token_file: token_file}
  end

  test "write!/1 writes the token at mode 0600 inside a 0700 dir", %{
    tmp: tmp,
    token_file: token_file
  } do
    :ok = TokenStore.write!("hunter2")

    assert File.read!(token_file) == "hunter2"
    assert File.stat!(token_file).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(tmp).mode |> Bitwise.band(0o777) == 0o700
  end

  test "read/0 returns {:ok, trimmed} or :error" do
    assert :error = TokenStore.read()

    :ok = TokenStore.write!("paste-me\n")
    assert {:ok, "paste-me"} = TokenStore.read()
  end

  test "delete/0 removes the token_file" do
    :ok = TokenStore.write!("x")
    :ok = TokenStore.delete()
    assert :error = TokenStore.read()
  end
end
