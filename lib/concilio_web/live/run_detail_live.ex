defmodule ConcilioWeb.RunDetailLive do
  @moduledoc """
  Run detail page: hierarchical timeline tree, per-event detail pane,
  metrics bar, and Replay / Re-run / Cancel actions.
  """

  use ConcilioWeb, :live_view

  alias Concilio.Councils.Roster
  alias Concilio.Runs
  alias Concilio.Runs.Run
  alias ConcilioWeb.RunStarter

  import ConcilioWeb.Components.JsonTree, only: [json_tree: 1]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    run = Runs.get!(id)

    initial_mode = if Run.terminal?(run.status), do: :static, else: :live

    if connected?(socket) and initial_mode == :live do
      Phoenix.PubSub.subscribe(Concilio.PubSub, "council_ex:run:#{run.run_id}")
    end

    {:ok,
     socket
     |> assign(:page_title, "Run #{String.slice(run.run_id, 0, 8)}")
     |> assign(:run, run)
     |> assign(:mode, initial_mode)
     |> assign(:cancel_requested?, false)
     |> assign(:conversation_id, Concilio.Chats.conversation_id_for_run(run.id))
     |> assign(:selected_event_idx, initial_selected_idx(run))}
  end

  # ── Events ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_event", %{"idx" => idx}, socket) do
    {:noreply, assign(socket, :selected_event_idx, String.to_integer(idx))}
  end

  def handle_event("scrub_event", %{"idx" => idx}, socket) do
    {:noreply, assign(socket, :selected_event_idx, parse_idx(idx))}
  end

  def handle_event("scrub_first", _params, socket) do
    {:noreply, assign(socket, :selected_event_idx, first_idx(socket.assigns.run))}
  end

  def handle_event("scrub_prev", _params, socket) do
    run = socket.assigns.run
    next = max(0, (socket.assigns.selected_event_idx || 0) - 1)
    {:noreply, assign(socket, :selected_event_idx, clamp_idx(run, next))}
  end

  def handle_event("scrub_next", _params, socket) do
    run = socket.assigns.run
    next = (socket.assigns.selected_event_idx || -1) + 1
    {:noreply, assign(socket, :selected_event_idx, clamp_idx(run, next))}
  end

  def handle_event("scrub_last", _params, socket) do
    {:noreply, assign(socket, :selected_event_idx, last_idx(socket.assigns.run))}
  end

  def handle_event("rerun", _params, socket) do
    run = socket.assigns.run
    # Re-fetch via Councils.get! so the template carries its preloaded
    # current_version (the run's preload only loads :template, not the
    # nested :current_version that RunStarter needs).
    template = Concilio.Councils.get!(run.template_id)

    case RunStarter.start(template, run.input_json,
           parent_run_id: run.id,
           rerun_of_run_id: run.run_id
         ) do
      {:ok, new_run} ->
        {:noreply, push_navigate(socket, to: ~p"/runs/#{new_run.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not re-run: #{inspect(reason)}")}
    end
  end

  def handle_event("cancel", _params, socket) do
    run = socket.assigns.run

    cond do
      run.status != :running ->
        {:noreply, put_flash(socket, :info, "Run is already #{run.status}.")}

      socket.assigns[:cancel_requested?] ->
        {:noreply, socket}

      true ->
        do_cancel(socket, run)
    end
  rescue
    _ ->
      {:noreply, put_flash(socket, :error, "Cancel not available for this run.")}
  end

  defp do_cancel(socket, run) do
    # Always optimistically flip our DB row to :cancelled. The runner cast
    # is fire-and-forget; without an immediate DB update, a refresh would
    # see :running again and re-show the Cancel button. The recorder is
    # tolerant of late events arriving for a terminal run.
    refreshed = Concilio.Runs.mark_status!(run, :cancelled)

    flash =
      case runner_pid(run.run_id) do
        pid when is_pid(pid) ->
          GenServer.cast(pid, :cancel)
          "Cancellation requested."

        nil ->
          Phoenix.PubSub.broadcast(
            Concilio.PubSub,
            "council_ex:run:#{run.run_id}",
            {:run_cancelled, run.run_id, %{reason: :orphaned}}
          )

          "Run marked cancelled (runner already gone)."
      end

    {:noreply,
     socket
     |> assign(:run, Runs.get!(refreshed.id))
     |> assign(:cancel_requested?, true)
     |> put_flash(:info, flash)}
  end

  defp runner_pid(run_id) do
    case Registry.lookup(CouncilEx.Runner.Registry, run_id) do
      [{pid, _}] -> if Process.alive?(pid), do: pid, else: nil
      _ -> nil
    end
  end

  # ── PubSub ──────────────────────────────────────────────────────────

  @impl true
  def handle_info(msg, socket) when is_tuple(msg) do
    case elem(msg, 0) do
      type when is_atom(type) -> handle_pubsub(type, msg, socket)
      _ -> {:noreply, socket}
    end
  end

  def handle_info(:refresh_terminal, socket), do: refresh_run(socket, :static)

  def handle_info(_other, socket), do: {:noreply, socket}

  defp handle_pubsub(:run_completed, _msg, socket), do: terminal_refresh(socket)
  defp handle_pubsub(:run_failed, _msg, socket), do: terminal_refresh(socket)
  defp handle_pubsub(:run_cancelled, _msg, socket), do: terminal_refresh(socket)

  defp handle_pubsub(_type, _msg, socket) do
    # Non-terminal event: re-read run + events so the timeline grows in
    # real time. RunRecorder persists rows before/around the broadcast;
    # any small race self-corrects on the next event.
    refresh_run(socket, socket.assigns.mode)
  end

  defp terminal_refresh(socket) do
    # Recorder persists the terminal row asynchronously; schedule a
    # second refresh so the timeline picks up the final event row even
    # if our PubSub delivery beat the DB write.
    Process.send_after(self(), :refresh_terminal, 250)
    refresh_run(socket, :static)
  end

  defp refresh_run(socket, new_mode) do
    fresh = Runs.get!(socket.assigns.run.id)
    {:noreply, socket |> assign(:run, fresh) |> assign(:mode, new_mode)}
  end

  defp initial_selected_idx(run) do
    case run.events do
      [] -> nil
      _ -> 0
    end
  end

  defp first_idx(run), do: initial_selected_idx(run)

  defp last_idx(run) do
    case run.events do
      [] -> nil
      events -> length(events) - 1
    end
  end

  defp clamp_idx(run, idx) do
    case run.events do
      [] -> nil
      events -> min(max(0, idx), length(events) - 1)
    end
  end

  defp parse_idx(idx) when is_binary(idx) do
    case Integer.parse(idx) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_idx(idx) when is_integer(idx), do: idx
  defp parse_idx(_), do: 0

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = Map.put_new(assigns, :cancel_requested?, false)

    ~H"""
    <Layouts.app flash={@flash} max_w="max-w-7xl">
      <div class="space-y-6">
        <.run_header
          run={@run}
          mode={@mode}
          cancel_requested?={@cancel_requested?}
          conversation_id={@conversation_id}
        />

        <.metrics run={@run} />

        <.member_roster roster={Roster.from_run(@run)} />

        <.scrubber events={@run.events} selected_idx={@selected_event_idx} />

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
          <div class="card bg-base-100 border border-base-300">
            <div class="card-body">
              <h2 class="card-title text-base">Timeline</h2>
              <.timeline run={@run} selected_idx={@selected_event_idx} />
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300">
            <div class="card-body">
              <h2 class="card-title text-base">Detail</h2>
              <.event_detail events={@run.events} selected_idx={@selected_event_idx} />
            </div>
          </div>
        </div>

        <%= if @run.result_json do %>
          <.final_result result_json={@run.result_json} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :events, :list, required: true
  attr :selected_idx, :integer, default: nil

  defp scrubber(assigns) do
    total = length(assigns.events)
    cur = assigns.selected_idx || 0
    assigns = assign(assigns, total: total, cur: cur)

    ~H"""
    <%= if @total > 0 do %>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body py-3 flex-row items-center gap-3 flex-wrap">
          <div class="flex items-center gap-1">
            <button
              class="btn btn-xs btn-ghost"
              phx-click="scrub_first"
              title="First event"
              disabled={@cur == 0}
            >
              <.icon name="hero-chevron-double-left" class="size-4" />
            </button>
            <button
              class="btn btn-xs btn-ghost"
              phx-click="scrub_prev"
              title="Previous event"
              disabled={@cur == 0}
            >
              <.icon name="hero-chevron-left" class="size-4" />
            </button>
            <button
              class="btn btn-xs btn-ghost"
              phx-click="scrub_next"
              title="Next event"
              disabled={@cur >= @total - 1}
            >
              <.icon name="hero-chevron-right" class="size-4" />
            </button>
            <button
              class="btn btn-xs btn-ghost"
              phx-click="scrub_last"
              title="Last event"
              disabled={@cur >= @total - 1}
            >
              <.icon name="hero-chevron-double-right" class="size-4" />
            </button>
          </div>

          <form phx-change="scrub_event" class="flex-1 flex items-center gap-2 min-w-0">
            <input
              type="range"
              name="idx"
              min="0"
              max={@total - 1}
              value={@cur}
              class="range range-xs flex-1"
            />
            <span class="text-xs font-mono whitespace-nowrap">
              {@cur + 1} / {@total}
            </span>
          </form>
        </div>
      </div>
    <% end %>
    """
  end

  attr :run, :map, required: true
  attr :mode, :atom, required: true
  attr :cancel_requested?, :boolean, default: false
  attr :conversation_id, :any, default: nil

  defp run_header(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-4">
      <div>
        <%= if @conversation_id do %>
          <.link navigate={~p"/c/#{@conversation_id}"} class="link link-hover text-sm">
            ← Back to chat
          </.link>
        <% else %>
          <.link navigate={~p"/runs"} class="link link-hover text-sm">← Runs</.link>
        <% end %>
        <h1 class="text-2xl font-semibold mt-1 font-mono break-all">{@run.run_id}</h1>
        <div class="text-xs text-base-content/60 mt-1 space-x-2">
          <.link
            navigate={~p"/councils/#{@run.template.id}"}
            class="link link-hover"
          >
            {@run.template.name}
          </.link>
          <span>· status:</span>
          <span class={["font-mono", status_color(@run.status)]}>{@run.status}</span>
          <span>· mode: {@mode}</span>
          <%= if @run.parent_run_id do %>
            <span>· re-run of</span>
            <.link navigate={~p"/runs/#{@run.parent_run_id}"} class="link link-hover font-mono">
              {@run.parent_run_id}
            </.link>
          <% end %>
        </div>
      </div>

      <div class="flex flex-wrap gap-2">
        <%= if @run.status == :running and not @cancel_requested? do %>
          <button class="btn btn-warning btn-sm" phx-click="cancel">
            Cancel
          </button>
        <% end %>
        <%= if @mode == :static do %>
          <button class="btn btn-ghost btn-sm" phx-click="rerun">
            Re-run
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  attr :run, :map, required: true

  defp metrics(assigns) do
    ~H"""
    <div class="stats stats-horizontal shadow w-full">
      <div class="stat py-2">
        <div class="stat-title text-xs">Wall</div>
        <div class="stat-value text-base tabular-nums">{wall_clock(@run)}</div>
      </div>
      <div class="stat py-2">
        <div class="stat-title text-xs">Tokens in</div>
        <div class="stat-value text-base tabular-nums">{format_int(@run.total_tokens_in)}</div>
      </div>
      <div class="stat py-2">
        <div class="stat-title text-xs">Tokens out</div>
        <div class="stat-value text-base tabular-nums">{format_int(@run.total_tokens_out)}</div>
      </div>
      <div class="stat py-2">
        <div class="stat-title text-xs">Errors</div>
        <div class="stat-value text-base">{@run.error_count}</div>
      </div>
      <div class="stat py-2">
        <div class="stat-title text-xs">Events</div>
        <div class="stat-value text-base">{length(@run.events)}</div>
      </div>
    </div>
    """
  end

  attr :roster, :map, required: true

  defp member_roster(assigns) do
    {visible, overflow} = roster_model_summary(assigns.roster)
    assigns = assigns |> assign(:visible_models, visible) |> assign(:overflow_count, overflow)

    ~H"""
    <%= if @roster.members != [] or @roster.chair do %>
      <details class="card bg-base-100 border border-base-300">
        <summary class="card-body py-3 cursor-pointer flex-row items-center gap-2">
          <h2 class="card-title text-base">Members</h2>
          <span class="badge badge-ghost badge-sm">
            {length(@roster.members)} {pluralize_word(length(@roster.members), "member")}
            <%= if @roster.chair do %>
              + chair
            <% end %>
          </span>
          <div class="ml-auto flex flex-wrap gap-1 justify-end">
            <span
              :for={{provider, model} <- @visible_models}
              class={[
                "badge badge-xs font-mono",
                ConcilioWeb.ProviderColors.badge_class(provider)
              ]}
            >
              {model}
            </span>
            <%= if @overflow_count > 0 do %>
              <span class="badge badge-ghost badge-xs">+{@overflow_count}</span>
            <% end %>
          </div>
        </summary>
        <div class="card-body pt-0 grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
          <.member_card :for={m <- @roster.members} card={m} />
          <.member_card :if={@roster.chair} card={@roster.chair} />
        </div>
      </details>
    <% end %>
    """
  end

  @model_badge_limit 4

  defp roster_model_summary(roster) do
    cards = roster.members ++ List.wrap(roster.chair)

    pairs =
      cards
      |> Enum.map(&{&1.provider, &1.model})
      |> Enum.reject(fn {_, m} -> is_nil(m) end)
      |> Enum.uniq_by(fn {_, m} -> m end)

    if length(pairs) <= @model_badge_limit do
      {pairs, 0}
    else
      {Enum.take(pairs, @model_badge_limit), length(pairs) - @model_badge_limit}
    end
  end

  attr :card, :map, required: true

  defp member_card(assigns) do
    ~H"""
    <div class={[
      "card bg-base-200 border",
      @card.kind == :chair && "border-primary",
      @card.kind != :chair && "border-base-300"
    ]}>
      <div class="card-body p-3 gap-1">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="font-mono text-sm font-semibold">{@card.id}</span>
          <%= if @card.kind == :chair do %>
            <span class="badge badge-primary badge-xs">chair</span>
          <% end %>
          <%= if @card.role do %>
            <span class="badge badge-ghost badge-xs">{@card.role}</span>
          <% end %>
        </div>
        <div class="flex flex-wrap items-center gap-1">
          <%= if @card.provider do %>
            <span class={[
              "badge badge-xs font-mono",
              ConcilioWeb.ProviderColors.badge_class(@card.provider)
            ]}>
              {@card.provider}
            </span>
          <% end %>
          <%= if @card.model do %>
            <span class={[
              "badge badge-xs font-mono",
              ConcilioWeb.ProviderColors.badge_class(@card.provider)
            ]}>
              {@card.model}
            </span>
          <% end %>
          <%= if @card.module do %>
            <span class="text-xs font-mono text-base-content/50">{@card.module}</span>
          <% end %>
        </div>
        <%= if @card.system_prompt do %>
          <details class="mt-1">
            <summary class="text-xs cursor-pointer text-base-content/70 hover:text-base-content">
              system prompt
            </summary>
            <pre class="text-xs whitespace-pre-wrap bg-base-100 rounded p-2 mt-1 max-h-64 overflow-y-auto">{@card.system_prompt}</pre>
          </details>
        <% end %>
      </div>
    </div>
    """
  end

  attr :run, :map, required: true
  attr :selected_idx, :any, required: true

  defp timeline(assigns) do
    rows = build_timeline_rows(assigns.run)
    assigns = assign(assigns, :rows, rows)

    ~H"""
    <ol
      id="timeline-list"
      phx-hook="AutoScroll"
      class="text-xs font-mono space-y-1 max-h-96 overflow-y-auto"
    >
      <li :for={row <- @rows}>
        <button
          phx-click="select_event"
          phx-value-idx={row.click_idx}
          class={[
            "text-left w-full px-1 py-0.5 rounded flex items-baseline gap-2",
            row.click_idx == @selected_idx && "bg-base-200",
            row.color
          ]}
        >
          <span class="text-base-content/40 tabular-nums">{row.time}</span>
          <span class="flex-1">
            {row.label}
            <span :if={row.summary != ""} class="text-base-content/60">{row.summary}</span>
          </span>
          <span :if={row.running?} class="loading loading-spinner loading-xs shrink-0" />
        </button>
      </li>
    </ol>
    """
  end

  defp build_timeline_rows(run) do
    base = run.started_at || (List.first(run.events) || %{}).inserted_at

    {rows, _open} =
      Enum.reduce(run.events, {[], %{}}, fn event, {acc, open} ->
        offset_ms = offset_ms(base, event.inserted_at)

        case event.type do
          "member_started" ->
            member = member_id_from(event)
            round = round_from(event)

            row = %{
              time: format_offset(offset_ms),
              label: "member=#{member} started",
              summary: round_suffix(round),
              color: "",
              click_idx: event.idx,
              running?: true,
              key: {:member, round, member}
            }

            {acc ++ [row], Map.put(open, {round, member}, length(acc))}

          "member_completed" ->
            member = member_id_from(event)
            round = round_from(event)
            duration_ms = duration_ms_from(event)

            label = "member=#{member} completed"
            time_label = format_offset(offset_ms)
            summary = [round_suffix(round), format_duration(duration_ms)] |> Enum.join(" ")

            updated_row = %{
              time: time_label,
              label: label,
              summary: summary,
              color: event_color(event.type),
              click_idx: event.idx,
              running?: false,
              key: {:member, round, member}
            }

            case Map.get(open, {round, member}) do
              nil ->
                {acc ++ [updated_row], open}

              pos ->
                {List.replace_at(acc, pos, updated_row), Map.delete(open, {round, member})}
            end

          _ ->
            row = %{
              time: format_offset(offset_ms),
              label: event.type,
              summary: event_summary(event),
              color: event_color(event.type),
              click_idx: event.idx,
              running?: false,
              key: {:event, event.idx}
            }

            {acc ++ [row], open}
        end
      end)

    rows
  end

  defp offset_ms(nil, _), do: nil
  defp offset_ms(_, nil), do: nil
  defp offset_ms(base, at), do: max(0, DateTime.diff(at, base, :millisecond))

  defp format_offset(nil), do: "--:--:--"

  defp format_offset(ms) when is_integer(ms) do
    total_s = div(ms, 1000)
    h = div(total_s, 3600)
    m = div(rem(total_s, 3600), 60)
    s = rem(total_s, 60)
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary()
  end

  defp format_duration(nil), do: ""
  defp format_duration(ms) when ms < 1_000, do: "(#{ms}ms)"
  defp format_duration(ms), do: "(#{Float.round(ms / 1_000, 1)}s)"

  defp round_suffix(nil), do: ""
  defp round_suffix(""), do: ""
  defp round_suffix(round), do: "round=#{round}"

  defp member_id_from(%{payload_json: %{"args" => args}}) when is_list(args),
    do: Enum.at(args, 1) |> to_string()

  defp member_id_from(_), do: "?"

  defp round_from(%{payload_json: %{"args" => args}}) when is_list(args),
    do: Enum.at(args, 0)

  defp round_from(_), do: nil

  defp duration_ms_from(%{payload_json: %{"args" => args}}) when is_list(args) do
    case Enum.at(args, 2) do
      %{"duration_ms" => ms} when is_integer(ms) -> ms
      _ -> nil
    end
  end

  defp duration_ms_from(_), do: nil

  attr :events, :list, required: true
  attr :selected_idx, :any, required: true

  defp event_detail(assigns) do
    ~H"""
    <%= if @selected_idx do %>
      <%= case Enum.find(@events, &(&1.idx == @selected_idx)) do %>
        <% nil -> %>
          <p class="text-base-content/60">Event not found.</p>
        <% event -> %>
          <div class="space-y-3">
            <div class="text-xs font-mono text-base-content/60">
              idx {event.idx} · <span class={event_color(event.type)}>{event.type}</span>
              · {Calendar.strftime(event.inserted_at, "%H:%M:%S.%f")}
            </div>

            <.event_pretty event={event} />

            <details class="text-xs">
              <summary class="cursor-pointer text-base-content/60 hover:text-base-content w-fit">
                Raw payload
              </summary>
              <div class="mt-2 font-mono bg-base-200 p-2 rounded">
                <.json_tree data={event.payload_json} />
              </div>
            </details>
          </div>
      <% end %>
    <% else %>
      <p class="text-base-content/60 text-sm">Click an event in the timeline to inspect.</p>
    <% end %>
    """
  end

  attr :event, :map, required: true

  defp event_pretty(%{event: %{type: type, payload_json: payload}} = assigns) do
    args = Map.get(payload, "args", [])
    assigns = assign(assigns, :args, args) |> assign(:type, type)

    case type do
      "run_started" ->
        input_map = Enum.at(args, 1, %{})

        assigns =
          assigns
          |> assign(:question, if(is_map(input_map), do: Map.get(input_map, "question")))
          |> assign(:context, if(is_map(input_map), do: Map.get(input_map, "context")))

        ~H"""
        <div class="space-y-2">
          <div class="text-sm font-medium">Run started</div>
          <.kv label="question" value={@question} />
          <.kv label="context" value={@context} />
        </div>
        """

      "round_started" ->
        ~H"""
        <div class="space-y-1">
          <div class="text-sm font-medium">
            Round started: <span class="font-mono">{Enum.at(@args, 0)}</span> (idx {Enum.at(@args, 1)})
          </div>
        </div>
        """

      "round_completed" ->
        round_result = Enum.at(args, 1, %{})
        duration = if is_map(round_result), do: Map.get(round_result, "duration_ms"), else: nil

        member_count =
          if is_map(round_result),
            do: round_result |> Map.get("member_results", %{}) |> map_size(),
            else: 0

        assigns = assigns |> assign(:duration, duration) |> assign(:member_count, member_count)

        ~H"""
        <div class="space-y-1">
          <div class="text-sm font-medium">
            Round completed: <span class="font-mono">{Enum.at(@args, 0)}</span>
          </div>
          <div class="text-xs text-base-content/60 flex flex-wrap gap-2">
            <%= if @member_count > 0 do %>
              <span>{@member_count} {pluralize_word(@member_count, "member")}</span>
            <% end %>
            <%= if @duration do %>
              <span>{format_ms(@duration)}</span>
            <% end %>
          </div>
        </div>
        """

      "member_started" ->
        ~H"""
        <div class="space-y-1">
          <div class="text-sm font-medium">
            Member started: <span class="font-mono">{Enum.at(@args, 1)}</span>
          </div>
          <div class="text-xs text-base-content/60">
            in round <span class="font-mono">{Enum.at(@args, 0)}</span>
          </div>
        </div>
        """

      "member_completed" ->
        result = Enum.at(args, 2, %{})
        response = if is_map(result), do: Map.get(result, "response", %{}), else: %{}
        content = if is_map(response), do: Map.get(response, "content"), else: nil
        status = if is_map(result), do: Map.get(result, "status"), else: nil
        duration = if is_map(result), do: Map.get(result, "duration_ms"), else: nil
        model = if is_map(response), do: Map.get(response, "model"), else: nil

        assigns =
          assigns
          |> assign(:content, content)
          |> assign(:status, status)
          |> assign(:duration, duration)
          |> assign(:model, model)

        ~H"""
        <div class="space-y-2">
          <div class="text-sm font-medium">
            Member completed: <span class="font-mono">{Enum.at(@args, 1)}</span>
          </div>
          <div class="flex flex-wrap gap-2 text-xs">
            <span class={[
              "badge badge-xs",
              member_status_badge(@status)
            ]}>
              {@status || "?"}
            </span>
            <%= if @model do %>
              <span class="badge badge-ghost badge-xs font-mono">{@model}</span>
            <% end %>
            <%= if @duration do %>
              <span class="text-base-content/60">{format_ms(@duration)}</span>
            <% end %>
          </div>
          <%= if @content do %>
            <.markdown body={@content} class="markdown rounded bg-base-200 p-3 text-sm" />
          <% end %>
        </div>
        """

      "run_completed" ->
        # CouncilEx tuple shape: {:run_completed, run_id, %Result{}} → after
        # dropping run_id, args is a single-element list with the Result map.
        result = Enum.at(args, 0, %{})
        final = if is_map(result), do: Map.get(result, "final"), else: nil
        content = if is_map(final), do: Map.get(final, "content"), else: nil
        status = if is_map(result), do: Map.get(result, "status"), else: nil
        assigns = assigns |> assign(:content, content) |> assign(:status, status)

        ~H"""
        <div class="space-y-2">
          <div class="text-sm font-medium text-success">
            Run completed
            <%= if @status do %>
              <span class={["badge badge-xs ml-1", member_status_badge(@status)]}>{@status}</span>
            <% end %>
          </div>
          <%= if @content do %>
            <.markdown body={@content} class="markdown rounded bg-base-200 p-3 text-sm" />
          <% end %>
        </div>
        """

      "run_failed" ->
        # Shape after dropping run_id: [errors_list, result_map]
        ~H"""
        <div class="space-y-1">
          <div class="text-sm font-medium text-error">Run failed</div>
          <div class="text-xs font-mono">{safe_text(Enum.at(@args, 0))}</div>
        </div>
        """

      "run_cancelled" ->
        ~H"""
        <div class="space-y-1">
          <div class="text-sm font-medium text-base-content/60">Run cancelled</div>
        </div>
        """

      _ ->
        ~H"""
        <div class="text-sm text-base-content/60">{@type}</div>
        """
    end
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp kv(assigns) do
    ~H"""
    <%= if @value not in [nil, ""] do %>
      <div>
        <span class="text-xs uppercase tracking-wide text-base-content/60">{@label}</span>
        <div class="rounded bg-base-200 p-2 text-sm whitespace-pre-wrap">{@value}</div>
      </div>
    <% end %>
    """
  end

  attr :result_json, :map, required: true

  defp final_result(assigns) do
    final = Map.get(assigns.result_json, "final") || %{}
    content = Map.get(final, "content")
    model = Map.get(final, "model")
    status = Map.get(assigns.result_json, "status")
    rounds = Map.get(assigns.result_json, "rounds", [])
    errors = Map.get(assigns.result_json, "errors", [])

    assigns =
      assigns
      |> assign(:content, content)
      |> assign(:model, model)
      |> assign(:status, status)
      |> assign(:round_count, length(rounds))
      |> assign(:error_count, length(errors))

    ~H"""
    <div class="card bg-base-100 border border-base-300">
      <div class="card-body space-y-3">
        <div class="flex items-baseline justify-between gap-2 flex-wrap">
          <h2 class="card-title text-base">Final result</h2>
          <div class="flex flex-wrap gap-2 text-xs">
            <%= if @status do %>
              <span class={["badge badge-sm", member_status_badge(@status)]}>{@status}</span>
            <% end %>
            <%= if @model do %>
              <span class="badge badge-ghost badge-sm font-mono">{@model}</span>
            <% end %>
            <span class="text-base-content/60">
              {@round_count} {pluralize_word(@round_count, "round")}
            </span>
            <%= if @error_count > 0 do %>
              <span class="text-error">{@error_count} {pluralize_word(@error_count, "error")}</span>
            <% end %>
          </div>
        </div>

        <%= if @content do %>
          <.markdown body={@content} class="markdown rounded bg-base-200 p-3 text-sm" />
        <% else %>
          <p class="text-sm text-base-content/60 italic">
            No final synthesis (chair did not run, or returned empty).
          </p>
        <% end %>

        <details class="text-xs">
          <summary class="cursor-pointer text-base-content/60 hover:text-base-content w-fit">
            Raw result
          </summary>
          <div class="mt-2 font-mono bg-base-200 p-2 rounded">
            <.json_tree data={@result_json} />
          </div>
        </details>
      </div>
    </div>
    """
  end

  defp pluralize_word(1, word), do: word
  defp pluralize_word(_, word), do: word <> "s"

  defp safe_text(nil), do: ""
  defp safe_text(s) when is_binary(s), do: s
  defp safe_text(n) when is_number(n), do: to_string(n)
  defp safe_text(a) when is_atom(a), do: Atom.to_string(a)
  defp safe_text(other), do: inspect(other)

  defp member_status_badge("ok"), do: "badge-success"
  defp member_status_badge("error"), do: "badge-error"
  defp member_status_badge("timeout"), do: "badge-warning"
  defp member_status_badge("skipped"), do: "badge-ghost"
  defp member_status_badge("eliminated"), do: "badge-ghost"
  defp member_status_badge("invalid_output"), do: "badge-warning"
  defp member_status_badge(_), do: "badge-ghost"

  # ── Helpers ─────────────────────────────────────────────────────────

  defp event_color("run_started"), do: "text-info"
  defp event_color("run_completed"), do: "text-success"
  defp event_color("run_failed"), do: "text-error"
  defp event_color("run_cancelled"), do: "text-base-content/60"
  defp event_color("round_started"), do: "text-primary"
  defp event_color("round_completed"), do: "text-primary"
  defp event_color("member_completed"), do: ""
  defp event_color(_), do: ""

  defp event_summary(%{type: "round_started", payload_json: %{"args" => [name, idx]}}),
    do: "round=#{name} idx=#{idx}"

  defp event_summary(%{type: "member_started", payload_json: %{"args" => [_round, member]}}),
    do: "member=#{member}"

  defp event_summary(%{type: "member_completed", payload_json: %{"args" => [_round, member, _]}}),
    do: "member=#{member}"

  defp event_summary(_), do: ""

  defp format_ms(nil), do: "—"
  defp format_ms(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_ms(ms), do: "#{Float.round(ms / 1_000, 1)}s"

  defp format_int(nil), do: "—"

  defp format_int(n) when is_integer(n) do
    Regex.replace(~r/\B(?=(\d{3})+(?!\d))/, Integer.to_string(n), ",")
  end

  defp format_int(other), do: to_string(other)

  defp wall_clock(%{total_duration_ms: ms}) when is_integer(ms), do: format_offset(ms)

  defp wall_clock(%{started_at: %DateTime{} = started, status: :running}) do
    format_offset(DateTime.diff(DateTime.utc_now(), started, :millisecond))
  end

  defp wall_clock(_), do: "—"

  defp status_color(:ok), do: "text-success"
  defp status_color(:partial), do: "text-warning"
  defp status_color(:error), do: "text-error"
  defp status_color(:cancelled), do: "text-base-content/60"
  defp status_color(:running), do: "text-info"
  defp status_color(_), do: ""
end
