defmodule ConcilioWeb.SettingsLive do
  @moduledoc """
  Settings shell with tabbed sub-routes.

  - About — versions + source links (M1).
  - Providers — enable / API key / endpoint override + working-set
    catalog with per-row test (M5).
  - Defaults — file-backed user defaults (`Concilio.Settings`).
  - Display / Storage — placeholders, land later.
  """

  use ConcilioWeb, :live_view

  alias Concilio.{Councils, Providers, Settings}
  alias Concilio.Providers.{Catalog, Model}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:tabs, tab_specs())
     |> assign(:test_in_flight, MapSet.new())
     |> assign(:edit_key_for, nil)
     |> assign(:add_custom_for, nil)
     |> assign(:configured?, Providers.any_configured?())
     |> load_provider_state()}
  end

  defp load_provider_state(socket) do
    settings_by_provider =
      Providers.list_settings()
      |> Map.new(fn s -> {s.provider, s} end)

    models_by_provider =
      Catalog.providers()
      |> Map.new(fn provider -> {provider, Providers.list_models(provider)} end)

    socket
    |> assign(:settings_by_provider, settings_by_provider)
    |> assign(:models_by_provider, models_by_provider)
    |> assign(:configured?, Providers.any_configured?())
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    tab = socket.assigns.live_action || :about

    socket =
      socket
      |> assign(:active_tab, tab)
      |> maybe_load_defaults(tab)

    {:noreply, socket}
  end

  defp maybe_load_defaults(socket, :defaults) do
    defaults = Settings.get_defaults()

    socket
    |> assign(:defaults, defaults)
    |> assign(:defaults_form, defaults_to_form(defaults))
    |> assign(:council_options, council_options())
    |> assign(:chairman_options, chairman_options())
  end

  defp maybe_load_defaults(socket, :display) do
    display = Settings.get_display()

    socket
    |> assign(:display, display)
    |> assign(:display_form, display_to_form(display))
  end

  defp maybe_load_defaults(socket, _), do: socket

  defp display_to_form(%Settings.Display{} = d) do
    to_form(
      %{
        "theme" => d.theme,
        "stream_tokens" => to_string(d.stream_tokens)
      },
      as: "display"
    )
  end

  defp defaults_to_form(%Settings.Defaults{} = d) do
    to_form(
      %{
        "council_template_slug" => d.council_template_slug || "",
        "chairman_model" => d.chairman_model || "",
        "member_timeout_ms" => Integer.to_string(d.member_timeout_ms),
        "failure_mode" => Atom.to_string(d.failure_mode)
      },
      as: "defaults"
    )
  end

  defp council_options do
    Councils.list_templates()
    |> Enum.map(fn t -> {t.name, t.slug} end)
  end

  defp chairman_options do
    Providers.list_working_set_models()
    |> Enum.map(fn m -> {"#{m.provider}/#{m.model_id}", m.model_id} end)
  end

  # ── Provider events ─────────────────────────────────────────────────

  @impl true
  def handle_event("provider_toggle", %{"provider" => provider_str}, socket) do
    provider = String.to_existing_atom(provider_str)
    setting = ensure_setting(socket, provider)
    new_enabled = !setting.enabled
    {:ok, _} = Providers.set_enabled(provider, new_enabled)

    socket =
      if new_enabled do
        socket
        |> ensure_council_models(provider)
        |> maybe_kick_off_pending_tests(provider)
      else
        socket
      end

    {:noreply, load_provider_state(socket)}
  end

  def handle_event("provider_remove", %{"provider" => provider_str}, socket) do
    provider = String.to_existing_atom(provider_str)
    :ok = Providers.remove(provider)

    {:noreply,
     socket
     |> put_flash(:info, "Removed #{provider} from your providers.")
     |> load_provider_state()}
  end

  def handle_event("edit_key_open", %{"provider" => provider_str}, socket) do
    {:noreply, assign(socket, :edit_key_for, String.to_existing_atom(provider_str))}
  end

  def handle_event("edit_key_cancel", _params, socket) do
    {:noreply, assign(socket, :edit_key_for, nil)}
  end

  def handle_event(
        "save_key",
        %{"provider" => provider_str, "api_key" => api_key},
        socket
      ) do
    provider = String.to_existing_atom(provider_str)
    {:ok, _} = Providers.set_api_key(provider, api_key)

    socket =
      socket
      |> assign(:edit_key_for, nil)
      |> put_flash(:info, "Saved API key for #{provider}.")
      |> ensure_council_models(provider)
      |> maybe_kick_off_pending_tests(provider)
      |> load_provider_state()

    {:noreply, socket}
  end

  def handle_event(
        "save_endpoint",
        %{"provider" => provider_str, "endpoint" => endpoint},
        socket
      ) do
    provider = String.to_existing_atom(provider_str)
    endpoint = if endpoint == "", do: nil, else: endpoint

    case Providers.set_endpoint_override(provider, endpoint) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Saved endpoint.") |> load_provider_state()}

      {:error, changeset} ->
        msg =
          Enum.map_join(
            Map.get(changeset, :errors, []),
            "; ",
            fn {field, {m, _}} -> "#{field}: #{m}" end
          )

        {:noreply, put_flash(socket, :error, "Endpoint invalid — #{msg}")}
    end
  end

  def handle_event("toggle_model", %{"id" => id}, socket) do
    model =
      Enum.find_value(socket.assigns.models_by_provider, fn {_p, models} ->
        Enum.find(models, &(&1.id == id))
      end)

    if model, do: {:ok, _} = Providers.toggle_in_working_set(model)
    {:noreply, load_provider_state(socket)}
  end

  def handle_event("test_model", %{"id" => id}, socket) do
    model =
      Enum.find_value(socket.assigns.models_by_provider, fn {_p, models} ->
        Enum.find(models, &(&1.id == id))
      end)

    case model do
      nil ->
        {:noreply, socket}

      m ->
        socket = assign(socket, :test_in_flight, MapSet.put(socket.assigns.test_in_flight, id))
        lv = self()

        Task.start(fn ->
          Providers.Tester.test(m)
          send(lv, {:test_complete, id})
        end)

        {:noreply, socket}
    end
  end

  def handle_event("add_custom_open", %{"provider" => provider_str}, socket) do
    {:noreply, assign(socket, :add_custom_for, String.to_existing_atom(provider_str))}
  end

  def handle_event("add_custom_cancel", _params, socket) do
    {:noreply, assign(socket, :add_custom_for, nil)}
  end

  def handle_event(
        "add_custom_save",
        %{"provider" => provider_str, "model_id" => model_id},
        socket
      ) do
    provider = String.to_existing_atom(provider_str)

    case Providers.add_user_model(provider, String.trim(model_id)) do
      {:ok, _model} ->
        {:noreply,
         socket
         |> assign(:add_custom_for, nil)
         |> put_flash(:info, "Added #{model_id}.")
         |> load_provider_state()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't add: #{inspect(reason)}")}
    end
  end

  # ── Defaults events ─────────────────────────────────────────────────

  def handle_event("defaults_save", %{"defaults" => attrs}, socket) do
    case Settings.put_defaults(attrs) do
      {:ok, defaults} ->
        {:noreply,
         socket
         |> assign(:defaults, defaults)
         |> assign(:defaults_form, defaults_to_form(defaults))
         |> put_flash(:info, "Defaults saved.")}

      {:error, :settings_not_started} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Settings service not running. Restart the dev server (mix phx.server)."
         )}

      {:error, errors} when is_list(errors) ->
        msg = Enum.map_join(errors, "; ", fn {field, m} -> "#{field}: #{m}" end)
        {:noreply, put_flash(socket, :error, "Couldn't save: #{msg}")}
    end
  end

  def handle_event("display_save", %{"display" => attrs}, socket) do
    case Settings.put_display(attrs) do
      {:ok, display} ->
        {:noreply,
         socket
         |> assign(:display, display)
         |> assign(:display_form, display_to_form(display))
         |> put_flash(:info, "Display saved. Theme applies on next page load.")}

      {:error, :settings_not_started} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Settings service not running. Restart the dev server (mix phx.server)."
         )}

      {:error, errors} when is_list(errors) ->
        msg = Enum.map_join(errors, "; ", fn {field, m} -> "#{field}: #{m}" end)
        {:noreply, put_flash(socket, :error, "Couldn't save: #{msg}")}
    end
  end

  @impl true
  def handle_info({:test_complete, id}, socket) do
    {:noreply,
     socket
     |> assign(:test_in_flight, MapSet.delete(socket.assigns.test_in_flight, id))
     |> load_provider_state()}
  end

  defp ensure_council_models(socket, provider) do
    model_ids = Councils.required_model_ids_for_provider(provider)

    case Providers.ensure_models_in_working_set(provider, model_ids) do
      [] ->
        socket

      models ->
        n = length(models)

        put_flash(
          socket,
          :info,
          "Auto-enabled #{n} council #{pluralize(n, "model")} for #{provider}."
        )
    end
  end

  defp maybe_kick_off_pending_tests(socket, provider) do
    if provider_ready?(provider) do
      required = MapSet.new(Councils.required_model_ids_for_provider(provider))

      pending =
        provider
        |> Providers.list_models()
        |> Enum.filter(fn m ->
          m.in_working_set and
            is_nil(m.last_test_status) and
            MapSet.member?(required, m.model_id) and
            not MapSet.member?(socket.assigns.test_in_flight, m.id)
        end)

      case pending do
        [] ->
          socket

        models ->
          lv = self()

          ids =
            Enum.map(models, fn m ->
              Task.start(fn ->
                Providers.Tester.test(m)
                send(lv, {:test_complete, m.id})
              end)

              m.id
            end)

          n = length(models)

          socket
          |> assign(
            :test_in_flight,
            MapSet.union(socket.assigns.test_in_flight, MapSet.new(ids))
          )
          |> put_flash(:info, "Started #{n} model #{pluralize(n, "test")} for #{provider}.")
      end
    else
      socket
    end
  end

  defp provider_ready?(provider) do
    setting = Providers.get_or_create_setting!(provider)
    setting.enabled and (provider == :ollama or not is_nil(setting.encrypted_credentials))
  end

  defp ensure_setting(socket, provider) do
    case Map.get(socket.assigns.settings_by_provider, provider) do
      nil -> Providers.get_or_create_setting!(provider)
      s -> s
    end
  end

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} max_w="max-w-6xl">
      <div class="space-y-6">
        <div class="flex items-baseline justify-between">
          <h1 class="text-2xl font-semibold">Settings</h1>
          <.link navigate={~p"/"} class="link link-hover text-sm">← Home</.link>
        </div>

        <nav role="tablist" class="tabs tabs-border">
          <.tab
            :for={{slug, label, path} <- @tabs}
            active?={slug == @active_tab}
            path={path}
            badge?={slug == :providers and not @configured?}
          >
            {label}
          </.tab>
        </nav>

        <div class="space-y-4">{render_tab(assigns)}</div>
      </div>
    </Layouts.app>
    """
  end

  defp render_tab(%{active_tab: :providers} = assigns) do
    {enabled, disabled} =
      Enum.split_with(Catalog.providers(), fn p ->
        s = assigns.settings_by_provider[p]
        s && s.enabled
      end)

    assigns = assign(assigns, enabled: enabled, disabled: disabled)

    ~H"""
    <div class="space-y-6">
      <section class="space-y-4">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
          Enabled
        </h2>

        <%= if @enabled == [] do %>
          <p class="text-sm text-base-content/60">
            No providers enabled yet. Pick one from "Available" below.
          </p>
        <% else %>
          <%= for provider <- @enabled do %>
            <.provider_card
              provider={provider}
              setting={@settings_by_provider[provider]}
              models={Map.get(@models_by_provider, provider, [])}
              edit_key_for={@edit_key_for}
              add_custom_for={@add_custom_for}
              test_in_flight={@test_in_flight}
            />
          <% end %>
        <% end %>
      </section>

      <section class="space-y-3">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
          Available
        </h2>

        <%= if @disabled == [] do %>
          <p class="text-sm text-base-content/60">All providers enabled.</p>
        <% else %>
          <ul class="flex flex-wrap gap-2">
            <li :for={provider <- @disabled}>
              <.provider_pill provider={provider} />
            </li>
          </ul>
        <% end %>
      </section>
    </div>
    """
  end

  defp render_tab(%{active_tab: :about} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 border border-base-300 overflow-hidden">
        <div class="card-body items-center text-center gap-4 py-10 bg-gradient-to-b from-primary/5 to-transparent">
          <div class="text-primary">
            <Layouts.logo class="size-16" />
          </div>
          <div class="space-y-1">
            <h2 class="text-3xl font-semibold tracking-tight">Concilio</h2>
            <p class="text-base text-base-content/70 max-w-xl">
              A local-first companion app for orchestrating multi-model
              LLM councils. Ask once. Hear several models deliberate.
              Pick the synthesized answer.
            </p>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 border border-base-300">
        <div class="card-body gap-3">
          <h3 class="text-lg font-medium">What Concilio is</h3>
          <p class="text-sm text-base-content/70 leading-relaxed">
            Concilio runs councils — small panels of LLMs that
            deliberate, peer-review each other, and have a chairman
            synthesize a single answer. It's the human-facing surface
            for the open-source <code class="font-mono">council_ex</code>
            engine: provider routing, structured output, deliberation
            patterns, and event timelines come from the library;
            Concilio adds chat, persistence, replay, a builder for
            custom councils, and a settings UI for your provider keys.
          </p>
          <p class="text-sm text-base-content/70 leading-relaxed">
            It runs locally on your machine, stores everything in a
            single SQLite file under <code class="font-mono">~/.concilio/</code>, and ships as a
            menu-bar app on macOS, Linux, and Windows. Single user,
            single host — by design.
          </p>
        </div>
      </div>

      <div class="card bg-base-100 border border-base-300">
        <div class="card-body gap-4">
          <h3 class="text-lg font-medium">What you can do with it</h3>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <.about_feature
              icon="hero-chat-bubble-left-right"
              title="Chat with any model"
              body="Plain-turn conversation with any model in your working set — and summon a council mid-thread when the question deserves more eyes."
            />
            <.about_feature
              icon="hero-rectangle-group"
              title="Build custom councils"
              body="Static modules ship with the app, or roll your own dynamic templates: members, rounds, peer review, chairman, output schemas. Versioned and immutable so historical runs reproduce."
            />
            <.about_feature
              icon="hero-clock"
              title="Replay every run"
              body="Council runs are persisted in full — event timeline, per-member output, metrics, tool calls. Replay re-broadcasts the saved events with original timing; re-run forks a new run from any past one."
            />
            <.about_feature
              icon="hero-key"
              title="Bring your own keys"
              body="Provider credentials are stored encrypted at rest (AES-256-GCM, key derived from CONCILIO_SECRET). Curate a working set per provider, ping each model with a one-shot test."
            />
          </div>
        </div>
      </div>

      <div class="card bg-base-100 border border-base-300">
        <div class="card-body gap-4">
          <h3 class="text-lg font-medium">Built on</h3>
          <p class="text-sm text-base-content/70">
            Concilio leans on a small, opinionated stack — battle-tested
            pieces of the Elixir / Phoenix ecosystem, plus Tauri for
            the desktop shell.
          </p>
          <div class="flex flex-wrap gap-2">
            <.about_chip label="council_ex" sub="LLM council engine" />
            <.about_chip label="Elixir" sub="language" />
            <.about_chip label="Erlang/OTP" sub="runtime" />
            <.about_chip label="Phoenix" sub="web framework" />
            <.about_chip label="LiveView" sub="real-time UI" />
            <.about_chip label="Ecto" sub="data + changesets" />
            <.about_chip label="SQLite" sub="storage" />
            <.about_chip label="Oban" sub="background jobs" />
            <.about_chip label="Bandit" sub="HTTP server" />
            <.about_chip label="Tailwind + DaisyUI" sub="styling" />
            <.about_chip label="Tauri 2" sub="desktop shell" />
          </div>
        </div>
      </div>

      <div class="card bg-base-100 border border-base-300">
        <div class="card-body gap-3">
          <h3 class="text-lg font-medium">Links</h3>
          <ul class="space-y-2 text-sm">
            <li>
              <a class="link link-primary" href="https://github.com/brewingelixir/concilio">
                Concilio source
              </a>
              <span class="text-base-content/50">— GitHub</span>
            </li>
            <li>
              <a class="link link-primary" href="https://github.com/brewingelixir/council_ex">
                council_ex
              </a>
              <span class="text-base-content/50">— upstream library</span>
            </li>
            <li>
              <a class="link link-primary" href="https://elixir-lang.org">Elixir</a>
              <span class="text-base-content/30">·</span>
              <a class="link link-primary" href="https://www.phoenixframework.org">Phoenix</a>
              <span class="text-base-content/30">·</span>
              <a class="link link-primary" href="https://tauri.app">Tauri</a>
            </li>
          </ul>
          <p class="text-xs text-base-content/50">
            Released under the Apache License 2.0.
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp render_tab(%{active_tab: :defaults} = assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-300">
      <div class="card-body space-y-4">
        <div>
          <h2 class="text-xl font-medium">Defaults</h2>
          <p class="text-sm text-base-content/60">
            Applied to new conversations. In-flight runs keep the values
            captured at start. Stored in <code class="font-mono">{Settings.path()}</code>.
          </p>
        </div>

        <.form for={@defaults_form} id="defaults-form" phx-submit="defaults_save" class="space-y-4">
          <.input
            field={@defaults_form[:council_template_slug]}
            type="select"
            label="Default council"
            options={[{"— none —", ""} | @council_options]}
          />

          <%= if @chairman_options == [] do %>
            <.input
              field={@defaults_form[:chairman_model]}
              type="text"
              label="Default chairman model"
              placeholder="e.g. claude-opus-4-7"
            />
            <p class="text-xs text-base-content/50 -mt-2">
              No models in working set yet. Enable models on the Providers tab to get a picker here.
            </p>
          <% else %>
            <.input
              field={@defaults_form[:chairman_model]}
              type="select"
              label="Default chairman model"
              options={[{"— none —", ""} | @chairman_options]}
            />
          <% end %>

          <.input
            field={@defaults_form[:member_timeout_ms]}
            type="number"
            label="Default member timeout (ms)"
            min="1000"
            max="600000"
            step="500"
          />

          <.input
            field={@defaults_form[:failure_mode]}
            type="select"
            label="Default failure mode"
            options={[
              {"continue (skip failed members)", "continue"},
              {"fail_fast (abort on first error)", "fail_fast"}
            ]}
          />

          <div>
            <button type="submit" class="btn btn-primary btn-sm">Save defaults</button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp render_tab(%{active_tab: :display} = assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-300">
      <div class="card-body space-y-4">
        <div>
          <h2 class="text-xl font-medium">Display</h2>
          <p class="text-sm text-base-content/60">
            Theme is the initial default for new browsers. Local navbar
            switches still win on this device via <code class="font-mono">localStorage</code>.
          </p>
        </div>

        <.form for={@display_form} id="display-form" phx-submit="display_save" class="space-y-4">
          <.input
            field={@display_form[:theme]}
            type="select"
            label="Theme"
            options={[
              {"system (follow OS)", "system"},
              {"light", "light"},
              {"dark", "dark"}
            ]}
          />

          <.input
            field={@display_form[:stream_tokens]}
            type="select"
            label="Token streaming"
            options={[
              {"on (render partial tokens as they arrive)", "true"},
              {"off (render messages only when complete)", "false"}
            ]}
          />

          <div>
            <button type="submit" class="btn btn-primary btn-sm">Save display</button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp render_tab(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-300">
      <div class="card-body space-y-2">
        <h2 class="text-xl font-medium">{tab_label(@active_tab)}</h2>
        <p class="text-base-content/70">
          This section isn't available yet.
        </p>
      </div>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true

  defp about_feature(assigns) do
    ~H"""
    <div class="flex gap-3 p-3 rounded-box border border-base-300/70 bg-base-200/40">
      <div class="text-primary shrink-0">
        <.icon name={@icon} class="size-6" />
      </div>
      <div class="space-y-1">
        <h4 class="font-medium text-sm">{@title}</h4>
        <p class="text-xs text-base-content/70 leading-relaxed">{@body}</p>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :sub, :string, required: true

  defp about_chip(assigns) do
    ~H"""
    <span class="inline-flex items-baseline gap-1.5 px-2.5 py-1 rounded-full border border-base-300 bg-base-200/40 text-xs">
      <span class="font-medium">{@label}</span>
      <span class="text-base-content/50">· {@sub}</span>
    </span>
    """
  end

  attr :provider, :atom, required: true

  defp provider_pill(assigns) do
    ~H"""
    <button
      class="btn btn-sm btn-outline"
      phx-click="provider_toggle"
      phx-value-provider={@provider}
      title={"Enable #{@provider}"}
    >
      <span class="capitalize">{@provider}</span>
      <span class="text-base-content/50">+</span>
    </button>
    """
  end

  attr :provider, :atom, required: true
  attr :setting, :any, required: true
  attr :models, :list, required: true
  attr :edit_key_for, :any, required: true
  attr :add_custom_for, :any, required: true
  attr :test_in_flight, :any, required: true

  defp provider_card(assigns) do
    working? = Providers.working?(assigns.setting, assigns.models)

    has_key? =
      assigns.setting &&
        (assigns.provider == :ollama or not is_nil(assigns.setting.encrypted_credentials))

    has_selected_model? = Enum.any?(assigns.models, & &1.in_working_set)

    confirm_msg =
      if working? do
        "Remove #{assigns.provider}? This deletes the stored API key and every tested model. " <>
          "You can add it back at any time."
      else
        nil
      end

    {status_label, status_class} =
      cond do
        working? ->
          {"working", "badge-success"}

        has_key? and has_selected_model? ->
          {"run model test", "badge-warning"}

        has_key? ->
          {"select model", "badge-warning"}

        true ->
          {"setup needed", "badge-ghost"}
      end

    assigns =
      assigns
      |> assign(:working?, working?)
      |> assign(:status_label, status_label)
      |> assign(:status_class, status_class)
      |> assign(:remove_confirm, confirm_msg)

    ~H"""
    <div class="card bg-base-100 border border-base-300">
      <div class="card-body space-y-3">
        <div class="flex items-start justify-between gap-3">
          <div class="flex items-baseline gap-3 min-w-0">
            <h3 class="text-lg font-medium capitalize truncate">{@provider}</h3>
            <span class={["badge badge-sm shrink-0", @status_class]}>
              {@status_label}
            </span>
          </div>

          <button
            class="btn btn-ghost btn-xs btn-square text-base-content/60 hover:text-error"
            phx-click="provider_remove"
            phx-value-provider={@provider}
            data-confirm={@remove_confirm}
            title={"Remove #{@provider}"}
            aria-label={"Remove #{@provider}"}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <.api_key_section
          provider={@provider}
          setting={@setting}
          editing?={@edit_key_for == @provider}
        />

        <.endpoint_section provider={@provider} setting={@setting} />

        <.models_section
          provider={@provider}
          models={@models}
          add_custom?={@add_custom_for == @provider}
          test_in_flight={@test_in_flight}
        />
      </div>
    </div>
    """
  end

  attr :provider, :atom, required: true
  attr :setting, :any, required: true
  attr :editing?, :boolean, required: true

  defp api_key_section(%{provider: :ollama} = assigns) do
    ~H"""
    <div class="text-xs text-base-content/60">No API key required for Ollama.</div>
    """
  end

  defp api_key_section(assigns) do
    ~H"""
    <div>
      <%= cond do %>
        <% @editing? -> %>
          <form phx-submit="save_key" class="space-y-2">
            <input type="hidden" name="provider" value={@provider} />
            <fieldset class="fieldset">
              <legend class="fieldset-legend">API key</legend>
              <input
                type="password"
                name="api_key"
                class="input w-full"
                autocomplete="off"
                placeholder="sk-..."
              />
            </fieldset>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
              <button type="button" class="btn btn-ghost btn-sm" phx-click="edit_key_cancel">
                Cancel
              </button>
            </div>
          </form>
        <% @setting && @setting.encrypted_credentials -> %>
          <div class="flex items-center gap-2 text-sm">
            <span class="font-mono text-base-content/70">••••••••••••</span>
            <button
              class="btn btn-ghost btn-xs"
              phx-click="edit_key_open"
              phx-value-provider={@provider}
            >
              Edit
            </button>
          </div>
        <% true -> %>
          <button
            class="btn btn-outline btn-sm"
            phx-click="edit_key_open"
            phx-value-provider={@provider}
          >
            + Add API key
          </button>
      <% end %>
    </div>
    """
  end

  attr :provider, :atom, required: true
  attr :setting, :any, required: true

  defp endpoint_section(assigns) do
    ~H"""
    <details class="text-sm">
      <summary class="cursor-pointer text-base-content/70 select-none">
        Advanced (endpoint override)
      </summary>
      <form phx-submit="save_endpoint" class="mt-3 space-y-2">
        <input type="hidden" name="provider" value={@provider} />
        <fieldset class="fieldset">
          <legend class="fieldset-legend">Endpoint URL</legend>
          <input
            type="url"
            name="endpoint"
            value={@setting && @setting.endpoint_override}
            class="input w-full"
            placeholder="https://api.example.com/v1"
          />
          <p class="fieldset-label">
            For Azure OpenAI, LiteLLM, or self-hosted proxies. Must be a full http(s) URL.
          </p>
        </fieldset>
        <button type="submit" class="btn btn-ghost btn-sm">Save</button>
      </form>
    </details>
    """
  end

  attr :provider, :atom, required: true
  attr :models, :list, required: true
  attr :add_custom?, :boolean, required: true
  attr :test_in_flight, :any, required: true

  defp models_section(assigns) do
    ~H"""
    <div class="space-y-2">
      <div class="flex items-center justify-between">
        <span class="text-sm font-medium">Models</span>
        <button
          class="btn btn-ghost btn-xs"
          phx-click="add_custom_open"
          phx-value-provider={@provider}
        >
          + Add custom
        </button>
      </div>

      <% {checked, unchecked} = Enum.split_with(@models, & &1.in_working_set) %>
      <ul class="text-sm divide-y divide-base-200">
        <.model_row :for={m <- checked} model={m} test_in_flight={@test_in_flight} />

        <li :if={@models == []} class="py-1.5 text-base-content/50">
          No models in catalog. Click "Add custom" or wait for the Ollama refresh.
        </li>
      </ul>

      <details :if={unchecked != []} class="text-sm mt-1">
        <summary class="cursor-pointer text-xs text-base-content/60 hover:text-base-content py-1">
          Show {length(unchecked)} more {pluralize(length(unchecked), "model")}
        </summary>
        <ul class="divide-y divide-base-200 mt-1">
          <.model_row :for={m <- unchecked} model={m} test_in_flight={@test_in_flight} />
        </ul>
      </details>

      <%= if @add_custom? do %>
        <form phx-submit="add_custom_save" class="mt-3 space-y-2">
          <input type="hidden" name="provider" value={@provider} />
          <fieldset class="fieldset">
            <legend class="fieldset-legend">Model id</legend>
            <input
              type="text"
              name="model_id"
              class="input w-full"
              placeholder="org/model-name"
              required
            />
            <p class="fieldset-label">
              Use the exact id the provider expects (e.g. <code>gpt-4o</code>, <code>anthropic/claude-3.5-sonnet</code>).
            </p>
          </fieldset>
          <div class="flex gap-2">
            <button type="submit" class="btn btn-primary btn-sm">Add</button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="add_custom_cancel">
              Cancel
            </button>
          </div>
        </form>
      <% end %>
    </div>
    """
  end

  attr :model, Model, required: true
  attr :test_in_flight, :any, required: true

  defp model_row(assigns) do
    ~H"""
    <li class="py-1.5 flex items-center gap-2">
      <input
        type="checkbox"
        class="checkbox checkbox-xs"
        checked={@model.in_working_set}
        phx-click="toggle_model"
        phx-value-id={@model.id}
      />
      <span class="font-mono">{@model.model_id}</span>
      <span :if={@model.source != :bundled} class="text-xs text-base-content/50">
        {@model.source}
      </span>
      <span class="ml-auto flex items-center gap-2">
        <.test_indicator model={@model} testing?={MapSet.member?(@test_in_flight, @model.id)} />
        <button
          class="btn btn-ghost btn-xs"
          phx-click="test_model"
          phx-value-id={@model.id}
          disabled={MapSet.member?(@test_in_flight, @model.id)}
        >
          Test
        </button>
      </span>
    </li>
    """
  end

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"

  attr :model, Model, required: true
  attr :testing?, :boolean, required: true

  defp test_indicator(%{testing?: true} = assigns) do
    ~H"""
    <span class="text-xs text-base-content/60">testing…</span>
    """
  end

  defp test_indicator(%{model: %Model{last_test_status: nil}} = assigns) do
    ~H"""
    <span class="text-xs text-base-content/40">—</span>
    """
  end

  defp test_indicator(assigns) do
    ~H"""
    <span
      class={[
        "text-xs font-mono cursor-help",
        @model.last_test_status == :ok && "text-success",
        @model.last_test_status == :error && "text-error"
      ]}
      title={@model.last_test_error || "no error"}
    >
      {@model.last_test_status} · {format_latency(@model.last_test_latency_ms)}
    </span>

    <%= if @model.last_test_status == :error and @model.last_test_error do %>
      <details class="text-xs">
        <summary class="cursor-pointer text-error/80 hover:text-error">why?</summary>
        <pre class="mt-1 p-2 bg-base-200 rounded text-error whitespace-pre-wrap break-words max-w-xs"><%= @model.last_test_error %></pre>
      </details>
    <% end %>
    """
  end

  defp format_latency(nil), do: "—"

  defp format_latency(ms) when is_integer(ms) and ms < 100,
    do: :erlang.float_to_binary(ms / 1000, decimals: 2) <> "s"

  defp format_latency(ms) when is_integer(ms),
    do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"

  attr :active?, :boolean, required: true
  attr :path, :string, required: true
  attr :badge?, :boolean, default: false
  slot :inner_block, required: true

  defp tab(assigns) do
    ~H"""
    <.link patch={@path} role="tab" class={["tab", @active? && "tab-active"]}>
      {render_slot(@inner_block)}
      <span :if={@badge?} class="ml-1 inline-block w-1.5 h-1.5 rounded-full bg-warning" />
    </.link>
    """
  end

  defp tab_specs do
    [
      {:providers, "Providers", ~p"/settings/providers"},
      {:defaults, "Defaults", ~p"/settings/defaults"},
      {:display, "Display", ~p"/settings/display"},
      {:about, "About", ~p"/settings/about"}
    ]
  end

  defp tab_label(slug) do
    case Enum.find(tab_specs(), fn {s, _, _} -> s == slug end) do
      {_, label, _} -> label
      _ -> "Settings"
    end
  end
end
