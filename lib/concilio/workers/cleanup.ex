defmodule Concilio.Workers.Cleanup do
  @moduledoc """
  Nightly cleanup. Prunes `run_events` rows for runs that finished
  more than `retention_days` ago. Defaults to 90 days. Set
  `:concilio, Concilio.Workers.Cleanup, retention_days: N` to override.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 1

  import Ecto.Query

  alias Concilio.Repo
  alias Concilio.Runs.{Run, RunEvent}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days() * 86_400, :second)

    {deleted, _} =
      Repo.delete_all(
        from e in RunEvent,
          where:
            e.run_id in subquery(
              from r in Run,
                where: not is_nil(r.finished_at) and r.finished_at < ^cutoff,
                select: r.id
            )
      )

    {:ok, %{events_deleted: deleted}}
  end

  defp retention_days do
    Application.get_env(:concilio, __MODULE__, [])
    |> Keyword.get(:retention_days, 90)
  end
end
