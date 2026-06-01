defmodule Concilio.AuthTest do
  use Concilio.DataCase, async: true

  alias Concilio.Auth

  describe "get_or_create_state/0" do
    test "creates the singleton row when missing" do
      state = Auth.get_or_create_state()

      assert state.id == 1
      assert state.kv == %{}
    end

    test "is idempotent" do
      a = Auth.get_or_create_state()
      b = Auth.get_or_create_state()

      assert a.id == b.id
    end
  end

  describe "rotate_secret!/0" do
    test "produces a new secret each call" do
      first = Auth.rotate_secret!().secret
      second = Auth.rotate_secret!().secret

      refute first == second
      assert byte_size(first) > 16
    end
  end

  describe "session_secret!/0" do
    test "fills the secret on first read and is stable on the next read" do
      first = Auth.session_secret!()
      second = Auth.session_secret!()

      assert first == second
    end
  end

  describe "put_token_hash/1" do
    test "persists the supplied hash" do
      {:ok, _} = Auth.put_token_hash("hashed!")
      assert Auth.get_state().token_hash == "hashed!"
    end
  end
end
