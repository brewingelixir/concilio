defmodule Concilio.Chats.Recovery do
  @moduledoc """
  One-shot startup task that fails plain assistant messages and council
  runs orphaned by a previous BEAM lifetime.

  - Plain completions run under
    `Concilio.Chats.PlainCompletion.Supervisor` (a `Task.Supervisor`)
    and do not survive a server restart. Any `messages` row still
    flagged `:pending` at boot is orphaned and gets stamped `:error`.

  - Council runs run under `Concilio.RunSupervisor` /
    `Concilio.RunRecorder.Supervisor`. Both are non-persistent, so any
    `runs` row still flagged `:running` at boot has no recorder
    receiving its events; we stamp those `:stuck` so the chat LV stops
    spinning forever.

  Idempotent. Safe to run on every boot.
  """

  use Task, restart: :transient

  require Logger

  import Ecto.Query, warn: false

  alias Concilio.Chats.Message
  alias Concilio.Repo
  alias Concilio.Runs.Run

  @stale_message "Lost: server restarted before reply arrived. Send again."

  @doc false
  def start_link(_opts) do
    Task.start_link(__MODULE__, :run, [])
  end

  @spec run() :: :ok
  def run do
    {plain_count, _} =
      from(m in Message,
        where: m.status == ^:pending and m.role == ^:assistant and is_nil(m.run_id)
      )
      |> Repo.update_all(
        set: [
          status: :error,
          content: @stale_message
        ]
      )

    {run_count, _} =
      from(r in Run, where: r.status == ^:running)
      |> Repo.update_all(
        set: [
          status: :stuck,
          finished_at: DateTime.utc_now()
        ]
      )

    if plain_count > 0 or run_count > 0 do
      Logger.info(
        "[Concilio.Chats.Recovery] marked #{plain_count} orphaned plain message(s) as :error, #{run_count} orphaned council run(s) as :stuck"
      )
    end

    :ok
  end
end
