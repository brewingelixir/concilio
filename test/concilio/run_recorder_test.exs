defmodule Concilio.RunRecorderTest do
  use Concilio.DataCase, async: false

  alias Concilio.Councils.{Template, TemplateVersion}
  alias Concilio.Repo
  alias Concilio.RunRecorder
  alias Concilio.Runs.{Run, RunEvent}

  # Stub runner that mimics the slice of the `Concilio.CouncilExRunner`
  # API the recorder uses: `validate/1` and `start_supervised_run/3`.
  # The stub doesn't spawn a real RunServer; instead it registers the
  # caller pid in an Agent so the test can drive it via send/2.
  defmodule StubRunner do
    def validate(_), do: :ok

    def start_supervised_run(_council, _input, _opts) do
      run_id = "stub-#{System.unique_integer([:positive])}"
      # The recorder doesn't actually monitor the runner pid; we
      # just need a valid pid to put in state.
      pid = spawn(fn -> :timer.sleep(:infinity) end)
      {:ok, run_id, pid}
    end
  end

  defmodule FailingRunner do
    def validate(_), do: :ok
    def start_supervised_run(_, _, _), do: {:error, :stub_boom}
  end

  setup do
    {:ok, template} =
      %Template{}
      |> Template.changeset(%{kind: :static, name: "Test", slug: "test"})
      |> Repo.insert()

    {:ok, version} =
      %TemplateVersion{}
      |> TemplateVersion.changeset(%{
        template_id: template.id,
        version: 1,
        spec_json: %{"members" => []}
      })
      |> Repo.insert()

    template =
      template
      |> Template.changeset(%{current_version_id: version.id})
      |> Repo.update!()

    %{template: template, version: version}
  end

  defp start_recorder(template, version, runner \\ StubRunner) do
    args = %{
      council: :TestCouncil,
      input: %{question: "what?"},
      template: template,
      version: version,
      run_opts: [],
      runner_module: runner
    }

    start_supervised!({RunRecorder, args})
  end

  test "init persists a Run row and exposes it via get_run/1",
       %{template: template, version: version} do
    pid = start_recorder(template, version)
    run = RunRecorder.get_run(pid)

    assert %Run{} = run
    assert run.status == :running
    assert run.input_json == %{"question" => "what?"}
  end

  test "full event sequence persists in order and finalizes the run",
       %{template: template, version: version} do
    pid = start_recorder(template, version)
    run = RunRecorder.get_run(pid)
    run_id = run.run_id
    ref = Process.monitor(pid)

    events = [
      {:run_started, run_id, :TestCouncil, %{question: "what?"}},
      {:round_started, run_id, :independent_analysis, 0},
      {:member_started, run_id, :independent_analysis, :alpha},
      {:member_completed, run_id, :independent_analysis, :alpha,
       %{__struct__: CouncilEx.MemberResult, member_id: :alpha, status: :ok}},
      {:round_completed, run_id, :independent_analysis,
       %{__struct__: CouncilEx.RoundResult, name: :independent_analysis, member_results: %{}}},
      {:run_completed, run_id,
       %{
         __struct__: CouncilEx.Result,
         run_id: run_id,
         council: :TestCouncil,
         input: %{},
         rounds: [],
         status: :ok,
         errors: [],
         metadata: %{duration_ms: 100, total_input_tokens: 5, total_output_tokens: 7}
       }}
    ]

    Enum.each(events, &send(pid, &1))

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    persisted_types =
      Repo.all(from(e in RunEvent, where: e.run_id == ^run.id, order_by: e.idx, select: e.type))

    assert persisted_types == [
             "run_started",
             "round_started",
             "member_started",
             "member_completed",
             "round_completed",
             "run_completed"
           ]

    refreshed = Repo.get!(Run, run.id)
    assert refreshed.status == :ok
    assert refreshed.finished_at
    assert refreshed.total_duration_ms == 100
    assert refreshed.total_tokens_in == 5
    assert refreshed.total_tokens_out == 7
  end

  test "drops :member_token events without persisting them",
       %{template: template, version: version} do
    pid = start_recorder(template, version)
    run = RunRecorder.get_run(pid)
    run_id = run.run_id
    ref = Process.monitor(pid)

    send(pid, {:run_started, run_id, :TestCouncil, %{}})

    send(
      pid,
      {:member_token, run_id, :independent_analysis, :alpha,
       %{__struct__: CouncilEx.StreamChunk, content: "hi"}}
    )

    send(
      pid,
      {:member_token, run_id, :independent_analysis, :alpha,
       %{__struct__: CouncilEx.StreamChunk, content: " there"}}
    )

    send(
      pid,
      {:run_completed, run_id,
       %{
         __struct__: CouncilEx.Result,
         run_id: run_id,
         council: :TestCouncil,
         input: %{},
         rounds: [],
         status: :ok,
         errors: [],
         metadata: %{duration_ms: 1, total_input_tokens: 0, total_output_tokens: 0}
       }}
    )

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    persisted_types =
      Repo.all(from(e in RunEvent, where: e.run_id == ^run.id, order_by: e.idx, select: e.type))

    assert persisted_types == ["run_started", "run_completed"]
  end

  test ":run_failed marks status as :error and stops",
       %{template: template, version: version} do
    pid = start_recorder(template, version)
    run = RunRecorder.get_run(pid)
    ref = Process.monitor(pid)

    send(pid, {:run_failed, run.run_id, %{__struct__: CouncilEx.Error, kind: :timeout}})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert Repo.get!(Run, run.id).status == :error
  end

  test ":run_cancelled marks status as :cancelled and stops",
       %{template: template, version: version} do
    pid = start_recorder(template, version)
    run = RunRecorder.get_run(pid)
    ref = Process.monitor(pid)

    send(pid, {:run_cancelled, run.run_id})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert Repo.get!(Run, run.id).status == :cancelled
  end

  test "init/1 returns {:stop, {:start_run_failed, reason}} when the runner errors",
       %{template: template, version: version} do
    args = %{
      council: :TestCouncil,
      input: %{},
      template: template,
      version: version,
      runner_module: FailingRunner
    }

    Process.flag(:trap_exit, true)
    assert {:error, {:start_run_failed, :stub_boom}} = RunRecorder.start_link(args)
  end
end
