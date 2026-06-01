defmodule Concilio.SerializationTest do
  use ExUnit.Case, async: true

  alias Concilio.Serialization

  describe "to_map/1" do
    test "passes plain values through" do
      assert Serialization.to_map(nil) == nil
      assert Serialization.to_map(42) == 42
      assert Serialization.to_map("hi") == "hi"
      assert Serialization.to_map(true) == true
      assert Serialization.to_map(false) == false
    end

    test "stringifies atom keys in maps" do
      assert Serialization.to_map(%{a: 1, b: %{c: 2}}) == %{
               "a" => 1,
               "b" => %{"c" => 2}
             }
    end

    test "stringifies non-bool atoms as values" do
      assert Serialization.to_map(:ok) == "ok"
    end

    test "encodes structs with __struct__ tag" do
      out = Serialization.to_map(%Range{first: 1, last: 5, step: 1})
      assert out["__struct__"] == "Range"
      assert out["first"] == 1
      assert out["last"] == 5
    end

    test "encodes DateTime as ISO8601 string" do
      dt = ~U[2026-05-05 12:00:00Z]
      assert Serialization.to_map(dt) == "2026-05-05T12:00:00Z"
    end

    test "encodes lists element-by-element" do
      assert Serialization.to_map([:a, %{b: 1}]) == ["a", %{"b" => 1}]
    end
  end

  describe "event_to_map/1" do
    test "encodes a council_ex run_started event" do
      event = {:run_started, "abc", MyApp.Council, %{question: "q"}}

      assert %{"type" => "run_started", "args" => args} = Serialization.event_to_map(event)
      # run_id is dropped from args since it lives on the parent runs row.
      assert args == ["Elixir.MyApp.Council", %{"question" => "q"}]
    end

    test "encodes a member_completed event with a struct payload" do
      member = %{__struct__: CouncilEx.MemberResult, member_id: :alpha, status: :ok}
      event = {:member_completed, "abc", :independent_analysis, :alpha, member}

      assert %{"type" => "member_completed", "args" => args} = Serialization.event_to_map(event)
      assert ["independent_analysis", "alpha", member_payload] = args
      assert member_payload["__struct__"] == "CouncilEx.MemberResult"
      assert member_payload["status"] == "ok"
    end

    test "round-trips through Jason" do
      event = {:round_started, "rid", :independent_analysis, 0}

      json =
        event
        |> Serialization.event_to_map()
        |> Jason.encode!()

      decoded = Jason.decode!(json)
      assert decoded["type"] == "round_started"
      assert Serialization.event_type(decoded) == :round_started
    end
  end
end
