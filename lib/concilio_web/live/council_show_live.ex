defmodule ConcilioWeb.CouncilShowLive do
  @moduledoc """
  Detail page for one council template. Shows the spec, recent runs,
  and a "Run now" button that dispatches a one-shot input.
  """

  use ConcilioWeb, :live_view

  alias Concilio.Councils
  alias Concilio.Runs
  alias ConcilioWeb.RunStarter

  import ConcilioWeb.Components.JsonTree, only: [json_tree: 1]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    template = Councils.get!(id)
    runs = Runs.list(template_id: template.id, limit: 10)

    {:ok,
     socket
     |> assign(:page_title, template.name)
     |> assign(:template, template)
     |> assign(:diagram, normalize_spec(template))
     |> assign(:diagram_view, :flow)
     |> assign(:configured?, Concilio.Providers.any_configured?())
     |> assign(:run_now_open?, false)
     |> assign(:run_now_form, to_form(%{"input" => "", "context" => ""}, as: :run_now))
     |> stream(:recent_runs, runs)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view =
      case params["view"] do
        "rounds" -> :rounds
        _ -> :flow
      end

    {:noreply, assign(socket, :diagram_view, view)}
  end

  @impl true
  def handle_event("run_now_open", _params, socket) do
    {:noreply, assign(socket, :run_now_open?, true)}
  end

  def handle_event("run_now_cancel", _params, socket) do
    {:noreply, assign(socket, :run_now_open?, false)}
  end

  def handle_event("use_sample", _params, socket) do
    case socket.assigns.template.samples do
      [] ->
        {:noreply, socket}

      samples ->
        sample = Enum.random(samples)

        prefill = %{
          "input" => Map.get(sample, "input", ""),
          "context" => Map.get(sample, "context", "")
        }

        {:noreply, assign(socket, :run_now_form, to_form(prefill, as: :run_now))}
    end
  end

  def handle_event("run_now_submit", %{"run_now" => params}, socket) do
    payload = build_run_input(params)

    case RunStarter.start(socket.assigns.template, payload) do
      {:ok, run} ->
        {:noreply,
         socket
         |> assign(:run_now_open?, false)
         |> put_flash(:info, "Run started.")
         |> push_navigate(to: ~p"/runs/#{run.id}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not start run: #{inspect(reason)}")
         |> assign(:run_now_open?, false)}
    end
  end

  def handle_event("clone", _params, socket) do
    case Concilio.Councils.clone_to_dynamic(socket.assigns.template) do
      {:ok, template} ->
        {:noreply, push_navigate(socket, to: ~p"/councils/#{template.id}/edit")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Clone failed: #{inspect(reason)}")}
    end
  end

  defp build_run_input(%{} = params) do
    question = params |> Map.get("input", "") |> to_string() |> String.trim()
    context = params |> Map.get("context", "") |> to_string() |> String.trim()

    base = %{question: question}
    if context == "", do: base, else: Map.put(base, :context, context)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} max_w="max-w-6xl">
      <div class="space-y-6">
        <%= if not @configured? do %>
          <div class="alert alert-warning">
            <span>
              No provider configured yet. Run-now will fail until you <.link
                navigate={~p"/settings/providers"}
                class="link font-medium"
              >
                set up a provider
              </.link>.
            </span>
          </div>
        <% end %>

        <div class="flex items-baseline justify-between">
          <div>
            <.link navigate={~p"/councils"} class="link link-hover text-sm">← Councils</.link>
            <h1 class="text-2xl font-semibold mt-1">{@template.name}</h1>
            <div class="text-xs text-base-content/60 font-mono">
              {@template.slug} · {@template.kind} ·
              v{(@template.current_version && @template.current_version.version) || "?"}
            </div>
          </div>
          <div class="flex gap-2">
            <button
              class="btn btn-primary btn-sm"
              phx-click="run_now_open"
              disabled={not @configured?}
            >
              Run now
            </button>
            <%= if @template.kind == :dynamic do %>
              <.link navigate={~p"/councils/#{@template.id}/edit"} class="btn btn-ghost btn-sm">
                Edit
              </.link>
            <% end %>
            <button class="btn btn-ghost btn-sm" phx-click="clone">
              Clone to dynamic
            </button>
          </div>
        </div>

        <%= if @template.description do %>
          <p class="text-sm text-base-content/70 whitespace-pre-wrap">
            {@template.description}
          </p>
        <% end %>

        <div class="flex justify-end">
          <div role="tablist" class="tabs tabs-boxed tabs-sm">
            <.link
              role="tab"
              patch={~p"/councils/#{@template.id}?view=flow"}
              class={["tab", @diagram_view == :flow && "tab-active"]}
            >
              Flow
            </.link>
            <.link
              role="tab"
              patch={~p"/councils/#{@template.id}?view=rounds"}
              class={["tab", @diagram_view == :rounds && "tab-active"]}
            >
              Rounds
            </.link>
          </div>
        </div>

        <%= case @diagram_view do %>
          <% :flow -> %>
            <.diagram_flow diagram={@diagram} />
          <% :rounds -> %>
            <.diagram_rounds diagram={@diagram} />
        <% end %>

        <details class="collapse collapse-arrow bg-base-100 border border-base-300">
          <summary class="collapse-title text-sm font-medium">Raw spec (JSON)</summary>
          <div class="collapse-content text-xs font-mono">
            <.json_tree data={format_spec_json(@template)} />
          </div>
        </details>

        <div class="card bg-base-100 border border-base-300">
          <div class="card-body">
            <h2 class="card-title text-base">Recent runs</h2>

            <div id="recent-runs" phx-update="stream" class="divide-y divide-base-200">
              <div
                :for={{dom_id, run} <- @streams.recent_runs}
                id={dom_id}
                class="py-2 flex items-center justify-between text-sm"
              >
                <.link navigate={~p"/runs/#{run.id}"} class="link link-hover font-mono">
                  {run.run_id}
                </.link>
                <span class="text-base-content/60">
                  {run.status} · {format_relative(run.started_at)}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%= if @run_now_open? do %>
        <dialog class="modal modal-open">
          <div class="modal-box max-w-lg">
            <h3 class="text-lg font-semibold">Run {@template.name}</h3>
            <p class="text-sm text-base-content/60 mt-1">
              One-shot run with no conversation. Output lands at /runs.
            </p>

            <.form for={@run_now_form} phx-submit="run_now_submit" class="space-y-4 mt-4">
              <fieldset class="fieldset">
                <div class="flex items-center justify-between">
                  <legend class="fieldset-legend">Input</legend>
                  <button
                    :if={@template.kind == :static and @template.samples != []}
                    type="button"
                    class="btn btn-xs btn-ghost"
                    phx-click="use_sample"
                  >
                    Random example input
                  </button>
                </div>
                <textarea
                  name="run_now[input]"
                  class="textarea w-full"
                  rows="6"
                  placeholder="Ask the council a question…"
                  required
                >{@run_now_form[:input].value}</textarea>
              </fieldset>

              <fieldset class="fieldset">
                <legend class="fieldset-legend">Context (optional)</legend>
                <textarea
                  name="run_now[context]"
                  class="textarea w-full"
                  rows="4"
                  placeholder="Background, constraints, prior facts — passed to members alongside the input as `context`."
                >{@run_now_form[:context].value}</textarea>
                <p class="fieldset-label text-xs text-base-content/50">
                  Members can reference this in their system prompt as `context`.
                </p>
              </fieldset>

              <div class="modal-action">
                <button type="button" class="btn btn-ghost" phx-click="run_now_cancel">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary">Start run</button>
              </div>
            </.form>
          </div>
        </dialog>
      <% end %>
    </Layouts.app>
    """
  end

  attr :diagram, :map, required: true

  defp diagram_flow(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-300">
      <div class="card-body">
        <h2 class="card-title text-base">Flow</h2>
        <p class="text-xs text-base-content/60 -mt-1">
          What happens when the council runs. Rounds top to bottom, chair at the end. Each row lists every member running in that round.
        </p>

        <div class="space-y-2 pt-2">
          <%= if @diagram.rounds == [] do %>
            <.flow_row
              label="Members"
              sublabel="(no rounds defined)"
              members={@diagram.members}
              type={nil}
            />
            <.flow_arrow_down :if={@diagram.chair} />
          <% else %>
            <%= for {round, idx} <- Enum.with_index(@diagram.rounds, 1) do %>
              <.flow_row
                label={"Round #{idx}"}
                sublabel={round.name}
                members={@diagram.members}
                type={round.type}
              />
              <.flow_arrow_down :if={idx < length(@diagram.rounds) or @diagram.chair} />
            <% end %>
          <% end %>

          <%= if @diagram.chair do %>
            <.flow_chair_row chair={@diagram.chair} />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :sublabel, :string, default: nil
  attr :members, :list, required: true
  attr :type, :atom, default: nil

  defp flow_row(assigns) do
    ~H"""
    <div class="border border-base-300 rounded-lg bg-base-50">
      <div class="flex items-center gap-2 px-3 py-2 border-b border-base-300">
        <span class="text-xs uppercase tracking-wide text-base-content/60 font-semibold">
          {@label}
        </span>
        <%= if @sublabel do %>
          <span class="font-mono text-sm font-semibold">{@sublabel}</span>
        <% end %>
        <%= if @type do %>
          <span class={["badge badge-xs ml-auto", round_type_badge_class(@type)]}>{@type}</span>
        <% end %>
      </div>
      <div class="p-3">
        <%= if @members == [] do %>
          <div class="text-sm text-base-content/50 italic">No members</div>
        <% else %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-2">
            <div :for={m <- @members} class="card bg-base-200 border border-base-300">
              <div class="card-body p-3 space-y-1">
                <div class="flex items-center justify-between gap-2">
                  <span class="font-mono text-sm font-semibold truncate">{m.id}</span>
                  <%= if m.module do %>
                    <span class="badge badge-ghost badge-xs">{m.module}</span>
                  <% end %>
                </div>
                <div class="flex flex-wrap gap-1">
                  <%= if m.provider do %>
                    <span class="badge badge-outline badge-xs">{m.provider}</span>
                  <% end %>
                  <%= if m.model do %>
                    <span class={[
                      "badge badge-xs font-mono",
                      provider_badge_class(m.provider)
                    ]}>
                      {m.model}
                    </span>
                  <% end %>
                </div>
                <%= if m.system_prompt && m.system_prompt != "" do %>
                  <details class="text-xs">
                    <summary class="cursor-pointer text-base-content/60 hover:text-base-content">
                      prompt
                    </summary>
                    <p class="mt-1 whitespace-pre-wrap text-base-content/70 italic">
                      {m.system_prompt}
                    </p>
                  </details>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :chair, :map, required: true

  defp flow_chair_row(assigns) do
    ~H"""
    <div class="border border-primary/40 rounded-lg bg-primary/5">
      <div class="flex items-center gap-2 px-3 py-2 border-b border-primary/40">
        <span class="text-xs uppercase tracking-wide text-primary font-semibold">Chair</span>
        <span class="font-mono text-sm font-semibold">synthesize</span>
      </div>
      <div class="p-3">
        <div class="card bg-primary/10 border border-primary/40 max-w-md">
          <div class="card-body p-3 space-y-1">
            <div class="flex items-center justify-between gap-2">
              <span class="font-mono text-sm font-semibold truncate">{@chair.id}</span>
              <%= if @chair.module do %>
                <span class="badge badge-ghost badge-xs">{@chair.module}</span>
              <% end %>
            </div>
            <div class="flex flex-wrap gap-1">
              <%= if @chair.provider do %>
                <span class="badge badge-outline badge-xs">{@chair.provider}</span>
              <% end %>
              <%= if @chair.model do %>
                <span class={[
                  "badge badge-xs font-mono",
                  provider_badge_class(@chair.provider)
                ]}>
                  {@chair.model}
                </span>
              <% end %>
            </div>
            <%= if @chair.system_prompt && @chair.system_prompt != "" do %>
              <details class="text-xs">
                <summary class="cursor-pointer text-base-content/60 hover:text-base-content">
                  prompt
                </summary>
                <p class="mt-1 whitespace-pre-wrap text-base-content/70 italic">
                  {@chair.system_prompt}
                </p>
              </details>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp flow_arrow_down(assigns) do
    ~H"""
    <div class="flex justify-center text-base-content/40 py-1">
      <.icon name="hero-arrow-down" class="size-5" />
    </div>
    """
  end

  defp provider_badge_class(p), do: ConcilioWeb.ProviderColors.badge_class(p)

  defp round_type_badge_class(:peer_review), do: "badge-warning"
  defp round_type_badge_class(:revision), do: "badge-secondary"
  defp round_type_badge_class(:debate), do: "badge-error"
  defp round_type_badge_class(:independent), do: "badge-info"
  defp round_type_badge_class(:synthesize), do: "badge-primary"
  defp round_type_badge_class(_), do: "badge-ghost"

  attr :diagram, :map, required: true

  defp diagram_rounds(assigns) do
    spec_json =
      Jason.encode!(%{
        "members" => assigns.diagram.members,
        "rounds" => assigns.diagram.rounds,
        "chair" => assigns.diagram.chair
      })

    assigns = assign(assigns, :spec_json, spec_json)

    ~H"""
    <div class="card bg-base-100 border border-base-300">
      <div class="card-body">
        <h2 class="card-title text-base">Rounds</h2>
        <p class="text-xs text-base-content/60">
          Snapshots over time. Each row = one round. Edges = which member outputs flow into which member inputs at the next round. Read top-to-bottom: input → round 1 → round 2 → … → chair.
        </p>
        <div
          id="council-rounds-diagram"
          phx-hook="CouncilDiagram"
          phx-update="ignore"
          data-spec={@spec_json}
          class="w-full h-[600px] rounded border border-base-300 bg-base-100"
        >
        </div>
        <div class="flex flex-wrap items-center gap-3 text-xs text-base-content/60">
          <span>Drag to pan · scroll to zoom</span>
          <span class="font-medium ml-2">Edge color:</span>
          <span class="flex items-center gap-1">
            <span class="inline-block w-4 h-0.5 bg-warning"></span>peer_review
          </span>
          <span class="flex items-center gap-1">
            <span class="inline-block w-4 h-0.5 bg-secondary"></span>revision
          </span>
          <span class="flex items-center gap-1">
            <span class="inline-block w-4 h-0.5 bg-error"></span>debate
          </span>
          <span class="flex items-center gap-1">
            <span class="inline-block w-4 h-0.5 bg-primary"></span>synthesize
          </span>
          <span class="flex items-center gap-1">
            <span
              class="inline-block w-4 h-0.5 bg-base-300"
              style="background-image: linear-gradient(to right, currentColor 50%, transparent 50%); background-size: 6px 1px;"
            >
            </span>
            input / independent
          </span>
        </div>
        <p class="text-[10px] text-base-content/50 italic">
          Round types inferred from name/module via heuristic — may not match runtime routing for custom rounds.
        </p>

        <details class="collapse collapse-arrow bg-base-200/40 border border-base-300 mt-2">
          <summary class="collapse-title text-sm font-medium">
            How to read this trellis
          </summary>
          <div class="collapse-content text-sm space-y-2 text-base-content/80">
            <ul class="list-disc pl-5 space-y-1">
              <li>
                <strong>Row</strong> = one round. Members appear once per round they participate in.
              </li>
              <li>
                <strong>Card</strong>
                = that member's output at that round. Round number + type shown on the card.
              </li>
              <li>
                <strong>Incoming edges</strong>
                = exactly the previous-round outputs that member reads as context.
              </li>
              <li>
                <strong>Dashed edge</strong>
                = original input being read directly (round 1, or independent rounds).
              </li>
            </ul>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-x-4 gap-y-1 mt-2">
              <div>
                <span class="badge badge-warning badge-xs mr-1">peer_review</span>
                full crossbar — every member reads every previous-round output.
              </div>
              <div>
                <span class="badge badge-secondary badge-xs mr-1">revision</span>
                each member only reads its own previous output.
              </div>
              <div>
                <span class="badge badge-error badge-xs mr-1">debate</span>
                full crossbar — debate partners read each other.
              </div>
              <div>
                <span class="badge badge-info badge-xs mr-1">independent</span>
                no peer reads — members only see the original input.
              </div>
              <div>
                <span class="badge badge-primary badge-xs mr-1">synthesize</span>
                chair reads every member from the last round.
              </div>
              <div>
                <span class="badge badge-ghost badge-xs mr-1">custom</span>
                unrecognized round name — defaults to crossbar; lossy assumption.
              </div>
            </div>
          </div>
        </details>
      </div>
    </div>
    """
  end

  defp format_spec_json(%{current_version: %{spec_json: spec}}) when is_map(spec), do: spec
  defp format_spec_json(_), do: %{}

  # ── Spec normalization ──────────────────────────────────────────────
  #
  # Two spec shapes flow through here:
  #   * dynamic (built in CouncilBuilderLive):
  #     `%{"members" => [%{id,model,...}], "chairman" => %{...}, "rounds" => ["name", ...]}`
  #   * static  (CouncilEx.Spec serialized):   tuples → lists, members are
  #     `[id, module_str, opts_map]`, chair likewise, rounds are
  #     `[module_str, opts_map]`.
  #
  # Normalize to a single rendering shape so the template stays simple.

  defp normalize_spec(%{current_version: %{spec_json: spec}}) when is_map(spec) do
    %{
      members: spec |> Map.get("members", []) |> Enum.map(&normalize_member/1),
      chair: normalize_chair(spec["chairman"] || spec["chair"]),
      rounds: spec |> Map.get("rounds", []) |> Enum.map(&normalize_round/1)
    }
  end

  defp normalize_spec(_), do: %{members: [], chair: nil, rounds: []}

  # Dynamic builder member: plain map with string keys.
  defp normalize_member(%{} = m) do
    %{
      id: m["id"] || "?",
      provider: m["provider"],
      model: m["model"],
      module: nil,
      system_prompt: m["system_prompt"]
    }
  end

  # Static `{id, module, opts}` tuple → 3-element list after Serialization.to_map.
  # `opts` may arrive as a map OR as a serialized keyword list:
  # `[["provider", "openai"], ["model", "gpt-4o-mini"]]`.
  defp normalize_member([id, module_str, opts]) do
    opts_map = opts_to_map(opts)

    %{
      id: to_string(id),
      provider: opts_map["provider"],
      model: opts_map["model"],
      module: short_module(module_str),
      system_prompt: opts_map["system_prompt"]
    }
  end

  defp normalize_member(other),
    do: %{id: inspect(other), provider: nil, model: nil, module: nil, system_prompt: nil}

  defp opts_to_map(opts) when is_map(opts), do: opts

  defp opts_to_map(opts) when is_list(opts) do
    Enum.into(opts, %{}, fn
      [k, v] when is_binary(k) -> {k, v}
      {k, v} when is_binary(k) -> {k, v}
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      _ -> {nil, nil}
    end)
    |> Map.delete(nil)
  end

  defp opts_to_map(_), do: %{}

  defp normalize_chair(nil), do: nil
  defp normalize_chair(other), do: normalize_member(other)

  # Dynamic round: plain string name OR `%{"type" => name, "opts" => map}`
  # (post-builder-rounds-editor). Static round: `[module_str, opts]`.
  defp normalize_round(name) when is_binary(name) do
    %{name: name, module: nil, type: infer_round_type(name, nil)}
  end

  defp normalize_round(%{"type" => name}) when is_binary(name) do
    %{name: name, module: nil, type: infer_round_type(name, nil)}
  end

  defp normalize_round([module_str, _opts]) do
    short = short_module(module_str)
    %{name: short || module_str, module: short, type: infer_round_type(short, module_str)}
  end

  defp normalize_round(other), do: %{name: inspect(other), module: nil, type: :custom}

  # Heuristic mapping from round name/module → routing type. Used until the
  # spec schema gains an explicit `type` field. See
  # `docs/CONCILIO_VISUALIZATION_RESEARCH.md` for the rationale.
  defp infer_round_type(name, module) do
    haystack =
      [name, module]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" ", &String.downcase/1)

    cond do
      Regex.match?(~r/peer[\s_-]*review/, haystack) -> :peer_review
      Regex.match?(~r/revis|iterate|refine/, haystack) -> :revision
      Regex.match?(~r/debate/, haystack) -> :debate
      Regex.match?(~r/independent/, haystack) -> :independent
      Regex.match?(~r/synth/, haystack) -> :synthesize
      true -> :custom
    end
  end

  defp short_module(nil), do: nil

  defp short_module(str) when is_binary(str) do
    str
    |> String.split(".")
    |> List.last()
  end

  defp format_relative(nil), do: "—"

  defp format_relative(%DateTime{} = dt) do
    seconds_ago = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds_ago < 60 -> "just now"
      seconds_ago < 3600 -> "#{div(seconds_ago, 60)}m ago"
      seconds_ago < 86_400 -> "#{div(seconds_ago, 3600)}h ago"
      true -> "#{div(seconds_ago, 86_400)}d ago"
    end
  end
end
