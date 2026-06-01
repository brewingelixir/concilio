defmodule ConcilioWeb.CouncilBuilderLiveTest do
  use ConcilioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Concilio.Auth
  alias Concilio.Councils
  alias Concilio.Providers
  alias Concilio.Repo

  setup %{conn: conn} do
    _ = Auth.rotate_secret!()
    {:ok, _model} = Providers.add_user_model(:openai, "gpt-4o-mini")

    conn = Plug.Test.init_test_session(conn, %{concilio_session: Auth.session_secret!()})
    %{conn: conn}
  end

  test "selecting a member model via form_change does not crash", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/councils/new")
    assert html =~ "New council"

    # Add a member row.
    html = lv |> element("button", "+ Add member") |> render_click()
    assert html =~ "Pick a model"

    params = %{
      "builder" => %{"name" => "Demo"},
      "members" => %{"0" => %{"model_ref" => "openai:gpt-4o-mini"}},
      "chairman" => %{"system_prompt" => "Synthesize."}
    }

    html = lv |> form("form", params) |> render_change()

    # Selected option should now reflect the chosen model.
    assert html =~ ~s(value="openai:gpt-4o-mini" selected)
  end

  test "submitting the form creates a dynamic template", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/councils/new")
    _ = lv |> element("button", "+ Add member") |> render_click()

    params = %{
      "builder" => %{"name" => "Demo Council"},
      "members" => %{"0" => %{"model_ref" => "openai:gpt-4o-mini"}},
      "chairman" => %{"model_ref" => "openai:gpt-4o-mini", "system_prompt" => "Synthesize."}
    }

    # Apply changes first so members/chairman assigns include the picked model.
    _ = lv |> form("form", params) |> render_change()

    {:ok, _show_lv, html} =
      lv
      |> form("form", params)
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "Demo Council"
  end

  describe "rounds editor" do
    test "default spec has one independent_analysis round", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/councils/new")
      assert html =~ "round #1"
      assert html =~ ~s(value="independent_analysis" selected)
    end

    test "add_round event grows the rounds list", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/councils/new")
      html = lv |> element("button", "+ Add round") |> render_click()
      assert html =~ "round #1"
      assert html =~ "round #2"
    end

    test "remove_round shrinks the list", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/councils/new")
      _ = lv |> element("button", "+ Add round") |> render_click()

      html =
        lv |> element("button[phx-click='remove_round'][phx-value-index='1']") |> render_click()

      assert html =~ "round #1"
      refute html =~ "round #2"
    end

    test "move_round_up swaps positions", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/councils/new")
      _ = lv |> element("button", "+ Add round") |> render_click()

      params = %{
        "rounds" => %{
          "0" => %{"type" => "independent_analysis"},
          "1" => %{"type" => "peer_review"}
        }
      }

      _ = lv |> form("form", params) |> render_change()

      _ =
        lv
        |> element("button[phx-click='move_round_down'][phx-value-index='0']")
        |> render_click()

      # State accessible via :sys.get_state on the LV pid.
      pid = lv.pid
      assigns = :sys.get_state(pid).socket.assigns
      assert [%{"type" => "peer_review"}, %{"type" => "independent_analysis"}] = assigns.rounds
    end
  end

  describe "spec persistence" do
    test "saves a council with rounds, role, overrides, default_profile, council tools, metadata",
         %{conn: conn} do
      _ = CouncilEx.Registry.register_tool("calc", Calc)

      {:ok, lv, _html} = live(conn, ~p"/councils/new")
      _ = lv |> element("button", "+ Add member") |> render_click()
      _ = lv |> element("button", "+ Add round") |> render_click()

      params = %{
        "builder" => %{"name" => "Full Spec", "description" => "demo"},
        "members" => %{
          "0" => %{
            "id" => "m1",
            "role" => "Skeptic",
            "model_ref" => "openai:gpt-4o-mini",
            "system_prompt" => "Be skeptical.",
            "overrides" => %{"temperature" => "0.7", "max_tokens" => "500"},
            "tools" => ["", "calc"]
          }
        },
        "chairman" => %{
          "id" => "chair",
          "role" => "Pundit",
          "model_ref" => "openai:gpt-4o-mini",
          "system_prompt" => "Synthesize."
        },
        "rounds" => %{
          "0" => %{"type" => "independent_analysis"},
          "1" => %{"type" => "peer_review", "opts_json" => "{\"max\": 2}"}
        },
        "council" => %{
          "default_profile" => "openai_mini",
          "router" => "",
          "tools" => ["", "calc"],
          "metadata_json" => "{\"version\": \"v1\"}"
        }
      }

      _ = lv |> form("form", params) |> render_change()

      {:ok, _show_lv, _html} =
        lv
        |> form("form", params)
        |> render_submit()
        |> follow_redirect(conn)

      template =
        Repo.one!(Concilio.Councils.Template)
        |> Repo.preload(:current_version)

      spec = template.current_version.spec_json
      [member] = spec["members"]
      assert member["role"] == "Skeptic"
      assert member["temperature"] == 0.7
      assert member["max_tokens"] == 500
      assert member["tools"] == ["calc"]

      assert spec["chairman"]["role"] == "Pundit"

      assert spec["rounds"] == [
               %{"type" => "independent_analysis", "opts" => %{}},
               %{"type" => "peer_review", "opts" => %{"max" => 2}}
             ]

      assert spec["default_profile"] == "openai_mini"
      assert spec["tools"] == ["calc"]
      assert spec["metadata"] == %{"version" => "v1"}
      refute Map.has_key?(spec, "router")

      CouncilEx.Registry.unregister(:tool, "calc")
    end

    test "saves a sub-council member by registered name", %{conn: conn} do
      _ =
        CouncilEx.Registry.register_sub_council("seo_audit", %CouncilEx.DynamicCouncil{
          id: "seo-stub",
          members: [],
          rounds: []
        })

      {:ok, lv, _html} = live(conn, ~p"/councils/new")
      _ = lv |> element("button", "+ Add member") |> render_click()

      # First flip kind=registered so the ref select renders. Use
      # render_change/3 directly (not form/2) because the picker swaps the
      # ref input shape based on the live kind value, which would trip up
      # the form helper's hidden-input check on a single combined post.
      _ =
        render_change(lv, "form_change", %{
          "members" => %{"0" => %{"sub_council_kind" => "registered"}}
        })

      params = %{
        "builder" => %{"name" => "Sub Demo"},
        "members" => %{
          "0" => %{
            "id" => "m1",
            "system_prompt" => "ignored",
            "sub_council_kind" => "registered",
            "sub_council_ref" => "seo_audit"
          }
        },
        "chairman" => %{
          "id" => "chair",
          "model_ref" => "openai:gpt-4o-mini",
          "system_prompt" => "Synthesize."
        }
      }

      _ = lv |> form("form", params) |> render_change()

      {:ok, _show_lv, _html} =
        lv
        |> form("form", params)
        |> render_submit()
        |> follow_redirect(conn)

      template =
        Repo.one!(Concilio.Councils.Template)
        |> Repo.preload(:current_version)

      [member] = template.current_version.spec_json["members"]
      assert member["sub_council"] == "seo_audit"
      refute Map.has_key?(member, "sub_council_kind")
      refute Map.has_key?(member, "sub_council_ref")

      CouncilEx.Registry.unregister(:sub_council, "seo_audit")
    end

    test "inline output schema is parsed from JSON textarea", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/councils/new")
      _ = lv |> element("button", "+ Add member") |> render_click()

      params = %{
        "builder" => %{"name" => "Inline Schema Demo"},
        "members" => %{
          "0" => %{
            "id" => "m1",
            "model_ref" => "openai:gpt-4o-mini",
            "system_prompt" => "ok",
            "output_schema_inline" => "{\"type\": \"object\"}"
          }
        },
        "chairman" => %{
          "id" => "chair",
          "model_ref" => "openai:gpt-4o-mini",
          "system_prompt" => "Synthesize."
        }
      }

      _ = lv |> form("form", params) |> render_change()

      {:ok, _show_lv, _html} =
        lv
        |> form("form", params)
        |> render_submit()
        |> follow_redirect(conn)

      template =
        Repo.one!(Concilio.Councils.Template)
        |> Repo.preload(:current_version)

      [member] = template.current_version.spec_json["members"]
      assert member["output_schema_inline"] == %{"type" => "object"}
    end
  end

  describe "edit mode hydration" do
    test "legacy spec with string round is upgraded to map shape on load", %{conn: conn} do
      {:ok, t} =
        Councils.create_dynamic_template(%{
          name: "Legacy",
          description: "",
          spec: %{
            "members" => [
              %{
                "id" => "m1",
                "provider" => "openai",
                "model" => "gpt-4o-mini",
                "system_prompt" => "x"
              }
            ],
            "chairman" => %{
              "id" => "chair",
              "provider" => "openai",
              "model" => "gpt-4o-mini",
              "system_prompt" => "y"
            },
            "rounds" => ["independent_analysis"]
          }
        })

      {:ok, lv, html} = live(conn, ~p"/councils/#{t.id}/edit")
      assert html =~ "Edit Legacy"

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert [%{"type" => "independent_analysis", "opts" => %{}}] = assigns.rounds
    end
  end
end
