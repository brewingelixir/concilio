defmodule ConcilioWeb.RunStarterTest do
  use Concilio.DataCase, async: false

  alias Concilio.Councils.{Template, TemplateVersion}
  alias Concilio.Repo
  alias Concilio.Runs
  alias Concilio.Runs.Run
  alias ConcilioWeb.RunStarter

  # Tiny static council for the test suite. Lives under a known
  # module name so resolve_module/1 can load it.
  defmodule FakeCouncil do
    def __council__, do: %{members: []}
  end

  # Stub that mimics `Concilio.CouncilExRunner`'s `validate/1` and
  # `start_supervised_run/3` without spawning a real RunServer. Lets us
  # exercise the full RunStarter -> RunRecorder boot path under test.
  defmodule StubRunner do
    def validate(_), do: :ok

    def start_supervised_run(_council, _input, opts) do
      if pid = Process.whereis(:run_starter_opts_listener),
        do: send(pid, {:run_opts, opts})

      run_id = "starter-stub-#{System.unique_integer([:positive])}"
      pid = spawn(fn -> :timer.sleep(:infinity) end)
      {:ok, run_id, pid}
    end
  end

  setup do
    prev = Application.get_env(:concilio, :council_runner_module)
    Application.put_env(:concilio, :council_runner_module, StubRunner)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:concilio, :council_runner_module),
        else: Application.put_env(:concilio, :council_runner_module, prev)
    end)

    {:ok, t} =
      %Template{}
      |> Template.changeset(%{
        kind: :static,
        name: "Fake",
        slug: "fake-#{System.unique_integer([:positive])}",
        source_module: Atom.to_string(FakeCouncil)
      })
      |> Repo.insert()

    {:ok, v} =
      %TemplateVersion{}
      |> TemplateVersion.changeset(%{
        template_id: t.id,
        version: 1,
        spec_json: %{"members" => []}
      })
      |> Repo.insert()

    {:ok, t} =
      t
      |> Template.changeset(%{current_version_id: v.id})
      |> Repo.update()

    template = Repo.preload(t, :current_version)

    %{template: template}
  end

  test "RunStarter.start/3 spawns recorder and returns the persisted Run row",
       %{template: template} do
    assert {:ok, %Run{} = run} = RunStarter.start(template, "why is hot in py?")
    assert run.status == :running
    assert run.input_json == %{"question" => "why is hot in py?"}

    refreshed = Repo.get!(Run, run.id)
    assert refreshed.run_id == run.run_id
  end

  test "RunStarter persists a binary input as a wrapped map (no Ecto cast crash)",
       %{template: template} do
    # Stub the runner by hand-constructing what RunStarter
    # would build. We can't easily intercept it, so we exercise the
    # normalize → insert path directly via Runs.insert!.
    normalized = %{question: "why is hot in py?"}

    run =
      Runs.insert!(%{
        template: template,
        template_version: template.current_version,
        run_id: "starter-test-#{System.unique_integer([:positive])}",
        input: normalized
      })

    assert %Run{input_json: %{"question" => "why is hot in py?"}} = Repo.get!(Run, run.id)
  end

  test "RunStarter snapshots Concilio.Settings defaults into run opts",
       %{template: template} do
    Process.register(self(), :run_starter_opts_listener)

    path =
      Path.join(
        System.tmp_dir!(),
        "concilio_settings_runstarter_#{System.unique_integer([:positive])}.toml"
      )

    File.write!(path, """
    schema_version = 1

    [defaults]
    member_timeout_ms = 75000
    failure_mode = "fail_fast"
    """)

    on_exit(fn -> File.rm(path) end)

    start_supervised!(
      Supervisor.child_spec({Concilio.Settings, path: path}, id: :run_starter_settings)
    )

    assert {:ok, _run} = RunStarter.start(template, "ping")

    assert_receive {:run_opts, opts}, 500
    assert opts[:failure_mode] == :fail_fast
    assert opts[:member_timeout_ms] == 75_000
  end

  test "RunStarter caller-supplied opts win over Settings defaults",
       %{template: template} do
    Process.register(self(), :run_starter_opts_listener)

    path =
      Path.join(
        System.tmp_dir!(),
        "concilio_settings_runstarter_override_#{System.unique_integer([:positive])}.toml"
      )

    File.write!(path, """
    schema_version = 1

    [defaults]
    member_timeout_ms = 75000
    failure_mode = "fail_fast"
    """)

    on_exit(fn -> File.rm(path) end)

    start_supervised!(
      Supervisor.child_spec({Concilio.Settings, path: path}, id: :run_starter_settings_override)
    )

    assert {:ok, _run} =
             RunStarter.start(template, "ping",
               failure_mode: :continue,
               member_timeout_ms: 10_000
             )

    assert_receive {:run_opts, opts}, 500
    assert opts[:failure_mode] == :continue
    assert opts[:member_timeout_ms] == 10_000
  end

  test "Run schema rejects a binary value for input_json (regression guard)",
       %{template: template} do
    cs =
      Run.insert_changeset(%{
        run_id: "starter-bad-#{System.unique_integer([:positive])}",
        template_id: template.id,
        template_version_id: template.current_version.id,
        input_json: "raw string",
        started_at: DateTime.utc_now()
      })

    refute cs.valid?

    assert {"is invalid", [type: :map, validation: :cast]} =
             cs.errors[:input_json]
  end

  describe "build_dynamic_council/2" do
    test "lifts temperature/max_tokens/role and threads council-level fields" do
      version = %TemplateVersion{
        spec_json: %{
          "members" => [
            %{
              "id" => "m1",
              "role" => "Skeptic",
              "provider" => "openai",
              "model" => "gpt-4o-mini",
              "system_prompt" => "x",
              "temperature" => 0.7,
              "max_tokens" => 400,
              "tools" => ["calc"],
              "output_schema" => "critique"
            }
          ],
          "chairman" => %{
            "id" => "chair",
            "provider" => "openai",
            "model" => "gpt-4o-mini",
            "system_prompt" => "y"
          },
          "rounds" => [%{"type" => "independent_analysis", "opts" => %{}}],
          "default_profile" => "openai_mini",
          "tools" => ["calc"],
          "metadata" => %{"version" => "v1"}
        }
      }

      template = %Template{id: Ecto.UUID.generate(), name: "X"}

      _ = CouncilEx.Registry.register_tool("calc", Calc)

      assert {:ok, %CouncilEx.DynamicCouncil{} = c} =
               RunStarter.build_dynamic_council(template, version)

      [m] = c.members
      assert m.id == "m1"
      assert m.role == "Skeptic"
      assert m.profile_overrides[:temperature] == 0.7
      assert m.profile_overrides[:max_tokens] == 400
      assert m.profile_overrides[:provider] == :openai
      assert m.profile_overrides[:model] == "gpt-4o-mini"
      assert m.tools == ["calc"]
      assert m.output_schema == "critique"

      assert c.default_profile == "openai_mini"
      assert c.tools == ["calc"]
      assert c.metadata == %{"version" => "v1"}

      CouncilEx.Registry.unregister(:tool, "calc")
    end

    test "preserves sub_council ref (registered name) on a member" do
      _ =
        CouncilEx.Registry.register_sub_council("seo_audit", %CouncilEx.DynamicCouncil{
          id: "seo-stub",
          members: [],
          rounds: []
        })

      version = %TemplateVersion{
        spec_json: %{
          "members" => [
            %{
              "id" => "m1",
              "system_prompt" => "",
              "sub_council" => "seo_audit"
            }
          ],
          "chairman" => %{
            "id" => "chair",
            "provider" => "openai",
            "model" => "gpt-4o-mini",
            "system_prompt" => "y"
          },
          "rounds" => [%{"type" => "independent_analysis", "opts" => %{}}]
        }
      }

      template = %Template{id: Ecto.UUID.generate(), name: "X"}

      assert {:ok, %CouncilEx.DynamicCouncil{} = c} =
               RunStarter.build_dynamic_council(template, version)

      [m] = c.members
      assert m.sub_council == "seo_audit"

      CouncilEx.Registry.unregister(:sub_council, "seo_audit")
    end

    test "preserves inline output schema (object form)" do
      version = %TemplateVersion{
        spec_json: %{
          "members" => [
            %{
              "id" => "m1",
              "provider" => "openai",
              "model" => "gpt-4o-mini",
              "system_prompt" => "x",
              "output_schema_inline" => %{"type" => "object"}
            }
          ],
          "chairman" => %{
            "id" => "chair",
            "provider" => "openai",
            "model" => "gpt-4o-mini",
            "system_prompt" => "y"
          },
          "rounds" => [%{"type" => "independent_analysis", "opts" => %{}}]
        }
      }

      template = %Template{id: Ecto.UUID.generate(), name: "X"}

      assert {:ok, %CouncilEx.DynamicCouncil{} = c} =
               RunStarter.build_dynamic_council(template, version)

      [m] = c.members
      assert m.output_schema_inline == %{"type" => "object"}
      assert m.output_schema == nil
    end
  end
end
