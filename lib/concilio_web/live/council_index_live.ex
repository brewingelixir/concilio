defmodule ConcilioWeb.CouncilIndexLive do
  @moduledoc """
  Lists every non-archived council template. Bundled examples (static)
  and user-built (dynamic) live side-by-side; a localStorage-persisted
  toggle hides the examples once the user is comfortable.
  """

  use ConcilioWeb, :live_view

  alias Concilio.Councils
  alias Concilio.Councils.Prebuilt
  alias Concilio.Providers

  @impl true
  def mount(_params, _session, socket) do
    templates = Councils.list_templates() |> annotate(&Providers.missing_requirements/1)
    prebuilts = Prebuilt.list()

    {:ok,
     socket
     |> assign(:page_title, "Councils")
     |> assign(:show_examples, true)
     |> assign(:templates, templates)
     |> assign(:prebuilts, prebuilts)}
  end

  defp annotate(templates, missing_fn) do
    Enum.map(templates, fn t ->
      reqs = Councils.spec_requirements(t)
      missing = missing_fn.(reqs)

      t
      |> Map.put(:missing_requirements, missing)
      |> Map.put(:requirements, reqs)
    end)
  end

  @impl true
  def handle_event("toggle_examples", params, socket) do
    next =
      case Map.get(params, "value") do
        v when v in [true, "true", "on"] -> true
        v when v in [false, "false", "off"] -> false
        _ -> !socket.assigns.show_examples
      end

    {:noreply, assign(socket, :show_examples, next)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} max_w="max-w-6xl">
      <div
        id="council-index"
        phx-hook="LocalStorageToggle"
        data-storage-key="concilio:show-examples"
        data-default="true"
        class="space-y-6"
      >
        <div class="flex items-baseline justify-between gap-4 flex-wrap">
          <div>
            <h1 class="text-2xl font-semibold">Councils</h1>
            <p class="text-sm text-base-content/60 mt-1">
              Reusable specs for multi-model deliberation. Examples ship with the app; click any to inspect, run, or clone into your own dynamic council.
            </p>
          </div>
          <div class="flex gap-2 items-center text-sm">
            <.link navigate={~p"/runs"} class="btn btn-ghost btn-sm">All runs →</.link>
            <.link navigate={~p"/councils/new"} class="btn btn-primary btn-sm">
              + New dynamic
            </.link>
          </div>
        </div>

        <div class="flex items-center gap-3 text-sm">
          <label class="label cursor-pointer gap-2 py-0">
            <input
              type="checkbox"
              class="toggle toggle-sm"
              checked={@show_examples}
              phx-click="toggle_examples"
              data-toggle-target="show-examples"
            />
            <span class="label-text">Show examples</span>
          </label>
          <span class="text-xs text-base-content/50">
            {Enum.count(@templates, &(&1.kind == :static))} examples · {Enum.count(@prebuilts)} prebuilt · {Enum.count(
              @templates,
              &(&1.kind == :dynamic)
            )} dynamic
          </span>
        </div>

        <% visible_templates = filter_visible(@templates, @show_examples) %>
        <% visible_prebuilts = @prebuilts %>
        <% visible_count = length(visible_templates) + length(visible_prebuilts) %>
        <div
          id="templates"
          class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3"
        >
          <.template_card :for={t <- visible_templates} template={t} />
          <.prebuilt_card :for={p <- visible_prebuilts} prebuilt={p} />
        </div>

        <%= if visible_count == 0 do %>
          <div class="card bg-base-200 border border-base-300">
            <div class="card-body items-center text-center py-10">
              <%= if @show_examples do %>
                <p class="text-base-content/70">No councils yet.</p>
              <% else %>
                <p class="text-base-content/70">No dynamic councils yet.</p>
              <% end %>
              <.link navigate={~p"/councils/new"} class="btn btn-primary btn-sm mt-2">
                + Build your first
              </.link>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp filter_visible(templates, true), do: templates
  defp filter_visible(templates, false), do: Enum.reject(templates, &(&1.kind == :static))

  attr :template, :any, required: true

  defp template_card(assigns) do
    runnable? = assigns.template.missing_requirements == []
    assigns = assign(assigns, :runnable?, runnable?)

    ~H"""
    <.link
      navigate={~p"/councils/#{@template.id}"}
      class={[
        "card bg-base-100 border border-base-300 hover:border-primary hover:shadow-md transition",
        not @runnable? && "opacity-70"
      ]}
    >
      <div class="card-body py-4 gap-2">
        <div class="flex items-start justify-between gap-2">
          <h3 class="text-lg font-medium leading-tight">{@template.name}</h3>
          <span class={[
            "badge badge-xs",
            @template.kind == :static && "badge-ghost",
            @template.kind == :dynamic && "badge-secondary"
          ]}>
            {@template.kind}
          </span>
        </div>

        <%= if @template.description do %>
          <p class="text-sm text-base-content/70 line-clamp-3">{@template.description}</p>
        <% end %>

        <%= if @template.requirements != [] do %>
          <div class="flex flex-wrap gap-1 mt-1">
            <span
              :for={{provider, count} <- provider_counts(@template.requirements)}
              class={["badge badge-sm gap-1", provider_badge_class(provider)]}
              title={"#{count} member(s) on #{provider}"}
            >
              <span class="capitalize">{provider}</span>
              <span :if={count > 1} class="opacity-70">×{count}</span>
            </span>
          </div>
        <% end %>

        <div class="text-xs text-base-content/60 font-mono mt-auto">
          {@template.slug} · v{(@template.current_version && @template.current_version.version) ||
            "?"}
        </div>

        <%= if not @runnable? do %>
          <div class="flex items-center gap-1 text-xs text-warning">
            <.icon name="hero-exclamation-triangle" class="size-3" />
            <span>
              Needs: {format_missing(@template.missing_requirements)}
            </span>
          </div>
        <% end %>
      </div>
    </.link>
    """
  end

  attr :prebuilt, :any, required: true

  defp prebuilt_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/councils/new?prebuilt=#{@prebuilt.slug}"}
      class="card bg-base-100 border border-base-300 border-dashed hover:border-primary hover:shadow-md transition"
    >
      <div class="card-body py-4 gap-2">
        <div class="flex items-start justify-between gap-2">
          <h3 class="text-lg font-medium leading-tight">{@prebuilt.name}</h3>
          <span class="badge badge-xs badge-info">prebuilt</span>
        </div>

        <p class="text-sm text-base-content/70 line-clamp-3">{@prebuilt.description}</p>

        <div class="flex flex-wrap gap-1 mt-1">
          <span :for={r <- @prebuilt.rounds} class="badge badge-sm badge-ghost gap-1">
            {r["type"]}
          </span>
        </div>

        <div class="text-xs text-base-content/60 font-mono mt-auto">
          {@prebuilt.slug} · scaffold
        </div>

        <div class="flex items-center gap-1 text-xs text-base-content/50">
          <.icon name="hero-cursor-arrow-rays" class="size-3" />
          <span>Click to seed a new dynamic council</span>
        </div>
      </div>
    </.link>
    """
  end

  defp format_missing(requirements) do
    Enum.map_join(requirements, ", ", fn {p, m} -> "#{p}/#{m}" end)
  end

  defp provider_counts(requirements) do
    requirements
    |> Enum.frequencies_by(fn {p, _m} -> p end)
    |> Enum.sort_by(fn {p, _c} -> Atom.to_string(p) end)
  end

  defp provider_badge_class(p), do: ConcilioWeb.ProviderColors.badge_class(p)
end
