defmodule Concilio.RunRecorder do
  @moduledoc """
  Single-writer GenServer for one council run. Owns the lifecycle:

  1. In `init/1`, calls `Concilio.CouncilExRunner.start_supervised_run/3`
     (a thin shim over `CouncilEx.Supervisor.start_link/4` introduced
     for the 0.12 upgrade) with `subscribe: true` and
     `supervisor: Concilio.RunSupervisor`. The `subscribe: true` flag
     installs the PubSub subscription on this process BEFORE the
     RunServer is spawned, so we cannot miss `:run_started` (or any
     subsequent event).
  2. Inserts the placeholder `runs` row via `Concilio.Runs.insert!/1`.
  3. Receives the nine `CouncilEx.Events` tuples and persists them via
     `Concilio.Runs.append_event!/4`. Token chunks are dropped.
  4. On terminal events (`:run_completed`, `:run_failed`,
     `:run_cancelled`), finalizes the run and stops normally; the
     `:transient` restart flag tells the supervisor not to restart.

  Every event is also relayed to the global `"concilio:runs"` topic
  via `:relay_topics`, so a future global activity feed can subscribe
  there without a per-run aggregator.

  The recorder owns all writes to `runs` / `run_events`; LVs are
  read-only on those tables (single-writer rule).
  """

  use GenServer, restart: :transient

  require Logger

  alias Concilio.Runs

  @idle_timeout :timer.minutes(30)
  @global_topic "concilio:runs"

  @type start_args :: %{
          required(:council) => module() | CouncilEx.DynamicCouncil.t(),
          required(:input) => map(),
          required(:template) => Concilio.Councils.Template.t(),
          required(:version) => Concilio.Councils.TemplateVersion.t(),
          optional(:parent_run_id) => Ecto.UUID.t() | nil,
          optional(:responder_kind) => atom(),
          optional(:run_opts) => keyword(),
          # Test seam — see init/1 below.
          optional(:runner_module) => module(),
          optional(:test_pre_inserted_run) => Concilio.Runs.Run.t()
        }

  @doc """
  Start a recorder under `Concilio.RunRecorder.Supervisor`.

  Returns `{:ok, pid}` on success, or `{:error, reason}` if the
  underlying runner shim failed (the recorder's `init/1` then returns
  `{:stop, {:start_run_failed, reason}}` so `start_link` propagates a
  clean error).
  """
  @spec start_link(start_args()) :: GenServer.on_start()
  def start_link(args) when is_map(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @doc """
  Block until the recorder has finished `init/1` and inserted its
  Run row, then return that row. Synchronous — used by `RunStarter`
  to hand the row back to the caller.
  """
  @spec get_run(pid()) :: Concilio.Runs.Run.t()
  def get_run(pid) do
    GenServer.call(pid, :get_run)
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(args) do
    runner = Map.get(args, :runner_module, default_runner_module())
    council = Map.fetch!(args, :council)
    input = Map.fetch!(args, :input)
    template = Map.fetch!(args, :template)
    version = Map.fetch!(args, :version)
    parent_run_id = Map.get(args, :parent_run_id)
    responder_kind = Map.get(args, :responder_kind, :council)
    extra_run_opts = Map.get(args, :run_opts, [])

    base_opts = [
      subscribe: true,
      supervisor: Concilio.RunSupervisor,
      relay_topics: [@global_topic]
    ]

    case start_supervised_run(runner, council, input, base_opts ++ extra_run_opts) do
      {:ok, run_id, runner_pid} ->
        run =
          Runs.insert!(%{
            template: template,
            template_version: version,
            run_id: run_id,
            input: input,
            parent_run_id: parent_run_id,
            responder_kind: responder_kind
          })

        state = %{
          run: run,
          idx: 0,
          runner_pid: runner_pid,
          idle_ref: schedule_idle_timeout()
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:start_run_failed, reason}}
    end
  end

  @impl true
  def handle_call(:get_run, _from, %{run: run} = state) do
    {:reply, run, state}
  end

  @impl true
  def handle_info({:run_started, _run_id, _council, _input} = ev, state) do
    {:noreply, persist(state, :run_started, ev)}
  end

  def handle_info({:round_started, _run_id, _round_name, _round_idx} = ev, state) do
    {:noreply, persist(state, :round_started, ev)}
  end

  def handle_info({:member_started, _run_id, _round_name, _member_id} = ev, state) do
    {:noreply, persist(state, :member_started, ev)}
  end

  # Per the kickoff: do not persist per-token chunks.
  def handle_info({:member_token, _run_id, _round_name, _member_id, _chunk}, state) do
    {:noreply, reset_idle(state)}
  end

  def handle_info({:tool_call_request, _run_id, _round_name, _member_id, _call} = ev, state) do
    {:noreply, persist(state, :tool_call_request, ev)}
  end

  def handle_info({:tool_call_result, _run_id, _round_name, _member_id, _result} = ev, state) do
    {:noreply, persist(state, :tool_call_result, ev)}
  end

  def handle_info(
        {:member_completed, _run_id, _round_name, _member_id, _member_result} = ev,
        state
      ) do
    {:noreply, persist(state, :member_completed, ev)}
  end

  def handle_info({:round_completed, _run_id, _round_name, _round_result} = ev, state) do
    {:noreply, persist(state, :round_completed, ev)}
  end

  def handle_info({:run_completed, _run_id, result} = ev, state) do
    state = persist(state, :run_completed, ev)
    Runs.finalize!(state.run, result)
    broadcast_finalized(state.run)
    {:stop, :normal, state}
  end

  def handle_info({:run_failed, _run_id, _error} = ev, state) do
    state = persist(state, :run_failed, ev)
    Runs.mark_status!(state.run, :error)
    broadcast_finalized(state.run)
    {:stop, :normal, state}
  end

  def handle_info({:run_cancelled, _run_id} = ev, state) do
    state = persist(state, :run_cancelled, ev)
    Runs.mark_status!(state.run, :cancelled)
    broadcast_finalized(state.run)
    {:stop, :normal, state}
  end

  def handle_info(:recorder_idle_timeout, %{run: run} = state) do
    Logger.warning("RunRecorder idle timeout for run_id=#{run.run_id}; marking stuck")
    Runs.mark_status!(run, :stuck)
    {:stop, :normal, state}
  end

  # Unknown / future event types: don't persist, but reset idle so a
  # busy run doesn't get reaped just because we don't recognize an
  # event shape.
  def handle_info(_other, state), do: {:noreply, reset_idle(state)}

  # ── helpers ────────────────────────────────────────────────────────────

  defp persist(%{run: run, idx: idx} = state, type, ev) do
    Runs.append_event!(run, idx, type, ev)
    %{state | idx: idx + 1} |> reset_idle()
  end

  # Emitted AFTER `Runs.finalize!` / `Runs.mark_status!` so subscribers can
  # safely re-read the row and see the terminal `result_json` / `status`.
  # `:run_completed` from CouncilEx fires before the DB write, so LVs that
  # refresh on it would race.
  defp broadcast_finalized(%{run_id: run_id}) when is_binary(run_id) do
    Phoenix.PubSub.broadcast(
      Concilio.PubSub,
      "council_ex:run:" <> run_id,
      {:concilio_finalized, run_id}
    )
  end

  defp broadcast_finalized(_), do: :ok

  defp reset_idle(%{idle_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | idle_ref: schedule_idle_timeout()}
  end

  defp reset_idle(state), do: %{state | idle_ref: schedule_idle_timeout()}

  defp schedule_idle_timeout do
    Process.send_after(self(), :recorder_idle_timeout, @idle_timeout)
  end

  # Test seam: callers may pass `:test_pre_inserted_run` (paired with a
  # stub runner module) so the test can drive the recorder without
  # actually spawning a CouncilEx RunServer. Production paths never
  # use this branch.
  defp start_supervised_run(runner, council, input, opts) do
    runner.start_supervised_run(council, input, opts)
  end

  defp default_runner_module do
    Application.get_env(:concilio, :council_runner_module, Concilio.CouncilExRunner)
  end
end
