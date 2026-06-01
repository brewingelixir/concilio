defmodule Concilio.ChatsTest do
  use Concilio.DataCase, async: true

  alias Concilio.Chats
  alias Concilio.Chats.Message

  describe "create_conversation/1 + list_conversations/1" do
    test "creates and lists" do
      {:ok, _} = Chats.create_conversation(%{title: "First"})
      {:ok, _} = Chats.create_conversation(%{title: "Second"})

      titles = Chats.list_conversations() |> Enum.map(& &1.title)
      assert "First" in titles
      assert "Second" in titles
    end

    test "skips soft-deleted" do
      {:ok, conv} = Chats.create_conversation(%{title: "X"})
      {:ok, _} = Chats.soft_delete_conversation(conv)

      refute Enum.any?(Chats.list_conversations(), &(&1.id == conv.id))
    end
  end

  describe "messages" do
    setup do
      {:ok, conv} = Chats.create_conversation(%{title: "T"})
      %{conv: conv}
    end

    test "append_user_message stores role :user", %{conv: conv} do
      {:ok, m} = Chats.append_user_message(conv, "hello")
      assert m.role == :user
      assert m.content == "hello"
      assert m.run_id == nil
    end

    test "append_plain_assistant marks as plain turn", %{conv: conv} do
      {:ok, m} = Chats.append_plain_assistant(conv, "gpt-4o", "hi back")

      assert m.role == :assistant
      assert m.run_id == nil
      assert m.model_used == "gpt-4o"
      assert Message.plain_turn?(m)
      refute Message.council_turn?(m)
    end

    test "list_messages returns chronological order", %{conv: conv} do
      {:ok, _} = Chats.append_user_message(conv, "one")
      {:ok, _} = Chats.append_plain_assistant(conv, "stub", "two")
      {:ok, _} = Chats.append_user_message(conv, "three")

      contents = conv.id |> Chats.list_messages() |> Enum.map(& &1.content)
      assert contents == ["one", "two", "three"]
    end
  end

  describe "build_history_input/2" do
    test "renders history + latest user prompt" do
      msgs = [
        %Message{role: :user, content: "first?"},
        %Message{role: :assistant, content: "first answer"},
        %Message{role: :user, content: "second?"},
        %Message{role: :assistant, content: "", run_id: "r-1"}
      ]

      out = Chats.build_history_input(msgs, "third?")

      assert out ==
               """
               User: first?
               Assistant: first answer
               User: second?
               Assistant: (council reply)
               User: third?
               """
               |> String.trim()
    end

    test "drops empty history" do
      assert Chats.build_history_input([], "go") == "User: go"
    end
  end
end
