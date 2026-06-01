defmodule Concilio.Workers.CleanupTest do
  use Concilio.DataCase, async: false

  use Oban.Testing, repo: Concilio.Repo

  alias Concilio.Councils.{Template, TemplateVersion}
  alias Concilio.Repo
  alias Concilio.Runs
  alias Concilio.Runs.RunEvent
  alias Concilio.Workers.Cleanup

  setup do
    {:ok, t} =
      %Template{}
      |> Template.changeset(%{
        kind: :static,
        name: "T",
        slug: "t-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    {:ok, v} =
      %TemplateVersion{}
      |> TemplateVersion.changeset(%{template_id: t.id, version: 1, spec_json: %{}})
      |> Repo.insert()

    %{template: t, version: v}
  end

  test "deletes events for runs older than retention", %{template: t, version: v} do
    Application.put_env(:concilio, Cleanup, retention_days: 1)

    old_run =
      Runs.insert!(%{
        template: t,
        template_version: v,
        run_id: "old-#{System.unique_integer([:positive])}",
        input: %{}
      })

    Runs.append_event!(old_run, 0, :run_started, {:run_started, old_run.run_id, :T, %{}})

    long_ago = DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second)

    Repo.update_all(
      from(r in Concilio.Runs.Run, where: r.id == ^old_run.id),
      set: [finished_at: long_ago, status: :ok]
    )

    new_run =
      Runs.insert!(%{
        template: t,
        template_version: v,
        run_id: "new-#{System.unique_integer([:positive])}",
        input: %{}
      })

    Runs.append_event!(new_run, 0, :run_started, {:run_started, new_run.run_id, :T, %{}})
    Repo.update_all(from(r in Concilio.Runs.Run, where: r.id == ^new_run.id), set: [status: :ok])

    {:ok, %{events_deleted: deleted}} = perform_job(Cleanup, %{})
    assert deleted == 1

    assert Repo.aggregate(from(e in RunEvent, where: e.run_id == ^old_run.id), :count) == 0
    assert Repo.aggregate(from(e in RunEvent, where: e.run_id == ^new_run.id), :count) == 1
  end
end
