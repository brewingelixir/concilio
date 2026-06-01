defmodule Concilio.CouncilExRunner do
  @moduledoc """
  Thin shim over the `CouncilEx` 0.12 run-start API. Preserves the
  `start_supervised_run/3` shape Concilio relied on under 0.11 so the
  recorder lifecycle ("subscribe BEFORE the runner emits :run_started")
  stays a single function call, and the test suite can keep swapping
  in stub runner modules via `:council_runner_module`.

  Strategy: pre-generate the `run_id`, subscribe the calling process
  to its PubSub topic, then start the runner under
  `Concilio.RunSupervisor` (a `CouncilEx.Supervisor` instance) with
  the same id baked into `:run_id`. PubSub delivery is racing nothing.
  """

  @default_supervisor Concilio.RunSupervisor

  @doc "Delegates to `CouncilEx.validate/1`."
  @spec validate(module() | CouncilEx.DynamicCouncil.t()) ::
          :ok | {:error, [map()]}
  def validate(council), do: CouncilEx.validate(council)

  @doc """
  Start a supervised council run. Returns `{:ok, run_id, pid}` on
  success.

  Recognised opts (mirrors what `RunRecorder` passes):

    * `:subscribe` — when `true`, subscribe the caller to the run's
      PubSub topic before the `RunServer` is spawned.
    * `:supervisor` — `CouncilEx.Supervisor` name to host the runner
      (default `Concilio.RunSupervisor`).
    * `:run_id` — explicit id; otherwise generated.

  Any other opts are forwarded as `user_opts` to `RunServer`
  (`:relay_topics`, `:recorder`, `:verbose`, …).
  """
  @spec start_supervised_run(
          module() | CouncilEx.DynamicCouncil.t(),
          term(),
          keyword()
        ) :: {:ok, String.t(), pid()} | {:error, term()}
  def start_supervised_run(council, input, opts \\ []) do
    {subscribe?, opts} = Keyword.pop(opts, :subscribe, false)
    {supervisor, opts} = Keyword.pop(opts, :supervisor, @default_supervisor)
    run_id = Keyword.get(opts, :run_id) || generate_run_id()
    opts = Keyword.put(opts, :run_id, run_id)

    if subscribe?, do: CouncilEx.subscribe(run_id)

    case CouncilEx.Supervisor.start_link(supervisor, council, input, opts) do
      {:ok, pid} ->
        {:ok, run_id, pid}

      {:error, _} = err ->
        if subscribe?, do: CouncilEx.unsubscribe(run_id)
        err
    end
  end

  defp generate_run_id do
    "run-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end
end
