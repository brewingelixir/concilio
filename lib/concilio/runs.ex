defmodule Concilio.Runs do
  @moduledoc """
  Persistence boundary for council runs.

  Public API:

  - `start/1` — insert the placeholder `runs` row, spin up a recorder,
    and return `{:ok, run, run_id_string}`.
  - `append_event!/4` — recorder-only path: insert an event row.
  - `finalize!/2` — recorder-only path: stamp the terminal status, the
    `result_json`, and aggregate counters.
  - `list/1`, `get!/1`, `get_by_run_id/1` — read paths.
  """

  import Ecto.Query, warn: false

  alias Concilio.Councils.{Template, TemplateVersion}
  alias Concilio.Repo
  alias Concilio.Runs.{Run, RunEvent}
  alias Concilio.Serialization

  @type start_attrs :: %{
          required(:template) => Template.t(),
          required(:template_version) => TemplateVersion.t(),
          required(:run_id) => String.t(),
          optional(:input) => term(),
          optional(:parent_run_id) => Ecto.UUID.t(),
          optional(:responder_kind) => Run.responder_kind()
        }

  @doc """
  Insert the placeholder run row. Caller is responsible for starting
  the recorder before invoking the council_ex runner.
  """
  @spec insert!(start_attrs()) :: Run.t()
  def insert!(%{template: template, template_version: version, run_id: run_id} = attrs) do
    input_map = Serialization.to_map(Map.get(attrs, :input, %{}))

    Run.insert_changeset(%{
      run_id: run_id,
      template_id: template.id,
      template_version_id: version.id,
      parent_run_id: Map.get(attrs, :parent_run_id),
      input_json: input_map,
      responder_kind: Map.get(attrs, :responder_kind, :council),
      started_at: DateTime.utc_now(),
      status: :running
    })
    |> Repo.insert!()
  end

  @doc """
  Insert one event row for a run. Recorder-only.
  """
  @spec append_event!(Run.t(), non_neg_integer(), atom(), term()) :: RunEvent.t()
  def append_event!(%Run{id: run_db_id}, idx, type, payload) when is_atom(type) do
    payload_map =
      cond do
        is_tuple(payload) -> Serialization.event_to_map(payload)
        is_map(payload) -> Serialization.to_map(payload)
        true -> %{"value" => Serialization.to_map(payload)}
      end

    %RunEvent{}
    |> RunEvent.changeset(%{
      run_id: run_db_id,
      idx: idx,
      type: Atom.to_string(type),
      payload_json: payload_map
    })
    |> Repo.insert!()
  end

  @doc """
  Apply a terminal `%CouncilEx.Result{}` to a run row. Recorder-only.
  """
  @spec finalize!(Run.t(), term()) :: Run.t()
  def finalize!(%Run{} = run, result) do
    metadata = Map.get(result, :metadata) || %{}

    attrs = %{
      result_json: Serialization.to_map(result),
      status: Map.get(result, :status) || :ok,
      finished_at: DateTime.utc_now(),
      total_duration_ms: Map.get(metadata, :duration_ms),
      total_tokens_in: Map.get(metadata, :total_input_tokens),
      total_tokens_out: Map.get(metadata, :total_output_tokens),
      total_cost_cents: Concilio.Pricing.result_cost_cents(result),
      error_count: length(Map.get(result, :errors) || [])
    }

    run
    |> Run.update_changeset(attrs)
    |> Repo.update!()
  end

  @doc """
  Mark a run as failed/stuck without a result. Recorder-only.
  """
  @spec mark_status!(Run.t(), Run.status()) :: Run.t()
  def mark_status!(%Run{} = run, status) do
    run
    |> Run.update_changeset(%{status: status, finished_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  # ── reads ────────────────────────────────────────────────────────────

  @doc """
  List recent runs, optionally scoped to a template.
  """
  @spec list(keyword()) :: [Run.t()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    query = from r in Run, order_by: [desc: r.inserted_at], limit: ^limit, preload: [:template]

    query =
      case Keyword.get(opts, :template_id) do
        nil -> query
        id -> from(r in query, where: r.template_id == ^id)
      end

    Repo.all(query)
  end

  @doc """
  Fetch a single run by its DB UUID with template + events preloaded.
  """
  @spec get!(Ecto.UUID.t()) :: Run.t()
  def get!(id) do
    Run
    |> Repo.get!(id)
    |> Repo.preload([:template, :template_version, events: from(e in RunEvent, order_by: e.idx)])
  end

  @doc """
  Fetch by the council_ex run_id string.
  """
  @spec get_by_run_id(String.t()) :: Run.t() | nil
  def get_by_run_id(run_id) when is_binary(run_id) do
    Repo.get_by(Run, run_id: run_id)
  end

  @doc """
  Most recent persisted event for a run, or `nil` if none yet.
  Used to seed the chat LV's progress UI when remounting mid-run.
  """
  @spec latest_event_for(Run.t()) :: RunEvent.t() | nil
  def latest_event_for(%Run{id: id}) do
    from(e in RunEvent,
      where: e.run_id == ^id,
      order_by: [desc: e.idx],
      limit: 1
    )
    |> Repo.one()
  end
end
