defmodule Concilio.Chats.HistoryTest do
  use ExUnit.Case, async: true

  alias Concilio.Chats.History
  alias Concilio.Chats.Message
  alias Concilio.Runs.Run

  test "user and plain assistant messages flatten in order" do
    msgs = [
      %Message{role: :user, content: "hello"},
      %Message{role: :assistant, content: "hi there", run: nil},
      %Message{role: :user, content: "tell me a joke"}
    ]

    assert History.build(msgs) == [
             %{role: "user", content: "hello"},
             %{role: "assistant", content: "hi there"},
             %{role: "user", content: "tell me a joke"}
           ]
  end

  test "council assistant pulls final.content from preloaded run" do
    run = %Run{result_json: %{"final" => %{"content" => "council says: go east"}}}

    msgs = [
      %Message{role: :user, content: "where to?"},
      %Message{role: :assistant, content: "", run: run},
      %Message{role: :user, content: "why?"}
    ]

    assert History.build(msgs) == [
             %{role: "user", content: "where to?"},
             %{role: "assistant", content: "council says: go east"},
             %{role: "user", content: "why?"}
           ]
  end

  test "council assistant with no final content is skipped" do
    run = %Run{result_json: %{}}

    msgs = [
      %Message{role: :user, content: "ping"},
      %Message{role: :assistant, content: "", run: run}
    ]

    assert History.build(msgs) == [%{role: "user", content: "ping"}]
  end

  test "council assistant with running run (no result_json) is skipped" do
    run = %Run{result_json: nil, status: :running}

    msgs = [
      %Message{role: :user, content: "?"},
      %Message{role: :assistant, content: "", run: run}
    ]

    assert History.build(msgs) == [%{role: "user", content: "?"}]
  end

  test "empty assistant content with no run is dropped" do
    msgs = [
      %Message{role: :user, content: "hi"},
      %Message{role: :assistant, content: "", run: nil}
    ]

    assert History.build(msgs) == [%{role: "user", content: "hi"}]
  end

  test "system role messages are dropped" do
    msgs = [
      %Message{role: :system, content: "be helpful"},
      %Message{role: :user, content: "hi"}
    ]

    assert History.build(msgs) == [%{role: "user", content: "hi"}]
  end
end
