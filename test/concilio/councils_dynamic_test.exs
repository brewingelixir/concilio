defmodule Concilio.CouncilsDynamicTest do
  use Concilio.DataCase, async: true

  alias Concilio.Councils

  describe "create_dynamic_template/1" do
    test "creates template + version 1 + flips current_version_id" do
      assert {:ok, t} =
               Councils.create_dynamic_template(%{
                 name: "Mine",
                 slug: "mine-#{System.unique_integer([:positive])}",
                 spec: %{"members" => [%{"id" => "alpha"}]}
               })

      assert t.kind == :dynamic
      assert t.current_version
      assert t.current_version.version == 1
      assert t.current_version.spec_json["members"] == [%{"id" => "alpha"}]
    end
  end

  describe "save_new_version/2" do
    test "appends a v2 row and points current_version_id at it" do
      {:ok, t} =
        Councils.create_dynamic_template(%{
          name: "Edit",
          slug: "edit-#{System.unique_integer([:positive])}",
          spec: %{"members" => [%{"id" => "v1"}]}
        })

      v1_id = t.current_version_id

      {:ok, t2} = Councils.save_new_version(t, %{"members" => [%{"id" => "v2"}]})

      assert t2.current_version.version == 2
      refute t2.current_version_id == v1_id
      assert t2.current_version.spec_json["members"] == [%{"id" => "v2"}]
    end
  end

  describe "clone_to_dynamic/2" do
    test "forks any template, seeding the spec + provenance" do
      {:ok, src} =
        Councils.create_dynamic_template(%{
          name: "Source",
          slug: "src-#{System.unique_integer([:positive])}",
          spec: %{"members" => [%{"id" => "x"}]}
        })

      {:ok, clone} = Councils.clone_to_dynamic(src)

      assert clone.kind == :dynamic
      assert clone.cloned_from_template_id == src.id
      assert clone.cloned_from_version_id == src.current_version_id
      assert clone.current_version.spec_json == src.current_version.spec_json
      refute clone.id == src.id
    end

    test "rewrites a serialized static spec into the dynamic-builder shape" do
      static_spec = %{
        "members" => [
          [
            "judge_alpha",
            "Elixir.Concilio.Councils.Members.Echo",
            [["provider", "openai"], ["model", "gpt-4o-mini"], ["system_prompt", "go"]]
          ]
        ],
        "chairman" => [
          "chair",
          "Elixir.Concilio.Councils.Members.Echo",
          %{"provider" => "anthropic", "model" => "claude-haiku"}
        ],
        "rounds" => [
          ["Elixir.CouncilEx.Rounds.IndependentAnalysis", %{}],
          "synthesis"
        ]
      }

      {:ok, src} =
        Councils.create_dynamic_template(%{
          name: "Static-shaped",
          slug: "static-shape-#{System.unique_integer([:positive])}",
          spec: static_spec
        })

      {:ok, clone} = Councils.clone_to_dynamic(src)
      cloned = clone.current_version.spec_json

      assert [%{"id" => "judge_alpha", "provider" => "openai", "model" => "gpt-4o-mini"} = m] =
               cloned["members"]

      assert m["system_prompt"] == "go"
      assert %{"id" => "chair", "provider" => "anthropic"} = cloned["chairman"]

      assert cloned["rounds"] == [
               %{"type" => "independent_analysis", "opts" => %{}},
               %{"type" => "synthesis", "opts" => %{}}
             ]
    end
  end
end
