defmodule ConcilioWeb.ChatLive do
  @moduledoc """
  Chat MVP. M4 surface:

  - Sidebar of recent conversations.
  - Main thread: user + assistant messages, council turns rendered
    distinctly from plain turns.
  - Input bar with a responder pill and a "Summon council" button.
  - Plain turns: stub message ("plain-model providers land at M5").
  - Council turns: full RunStarter integration, live event subscribe.
  """

  use ConcilioWeb, :live_view

  require Logger

  alias Concilio.Chats
  alias Concilio.Chats.CouncilRefs
  alias Concilio.Chats.History
  alias Concilio.Chats.Message
  alias Concilio.Councils
  alias Concilio.Providers
  alias Concilio.Runs
  alias ConcilioWeb.RunStarter

  @impl true
  def mount(params, _session, socket) do
    conversations = Chats.list_conversations(limit: 50)
    templates = Councils.list_templates(kind: :static)
    working_set = Providers.list_working_set_models()

    socket =
      socket
      |> assign(:page_title, "Chat")
      |> assign(:conversations, conversations)
      |> assign(:templates, templates)
      |> assign(:working_set_models, working_set)
      |> assign(:configured?, Providers.any_configured?())
      |> assign(:summon_open?, false)
      |> assign(:summon_form, summon_form())
      |> assign(:composer, %{"text" => ""})
      |> assign(:active_run_id, nil)
      |> assign(:run_progress, %{})
      |> assign(:subscribed_run_ids, [])
      |> assign(:subscribed_chat_id, nil)
      |> assign(:editing_title?, false)
      |> assign(:title_draft, "")
      |> load_conversation(params["id"])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_conversation(socket, params["id"])}
  end

  defp load_conversation(socket, nil) do
    socket
    |> unsubscribe_runs()
    |> unsubscribe_chat()
    |> assign(:conversation, nil)
    |> assign(:messages, [])
    |> assign(:run_progress, %{})
    |> assign(:active_run_id, nil)
    |> assign(:editing_title?, false)
    |> assign(:title_draft, "")
  end

  defp load_conversation(socket, id) when is_binary(id) do
    conv = Chats.get_conversation!(id)
    msgs = Chats.list_messages(conv.id)
    pending = pending_council_runs(msgs)
    socket = socket |> unsubscribe_runs() |> unsubscribe_chat()
    pending_ids = Enum.map(pending, & &1.run_id)

    if connected?(socket) do
      Enum.each(pending_ids, fn rid ->
        Phoenix.PubSub.subscribe(Concilio.PubSub, "council_ex:run:" <> rid)
      end)

      Phoenix.PubSub.subscribe(Concilio.PubSub, "concilio:chat:" <> conv.id)
    end

    progress_seed =
      pending
      |> Enum.map(fn run -> {run.run_id, seed_progress_from_run(run)} end)
      |> Map.new()

    active_run_id =
      case pending do
        [run | _] -> run.run_id
        [] -> nil
      end

    socket
    |> assign(:conversation, conv)
    |> assign(:messages, msgs)
    |> assign(:run_progress, progress_seed)
    |> assign(:subscribed_run_ids, pending_ids)
    |> assign(:subscribed_chat_id, conv.id)
    |> assign(:active_run_id, active_run_id)
    |> assign(:editing_title?, false)
    |> assign(:title_draft, "")
  end

  defp unsubscribe_runs(socket) do
    if connected?(socket) do
      Enum.each(socket.assigns[:subscribed_run_ids] || [], fn rid ->
        Phoenix.PubSub.unsubscribe(Concilio.PubSub, "council_ex:run:" <> rid)
      end)
    end

    assign(socket, :subscribed_run_ids, [])
  end

  defp unsubscribe_chat(socket) do
    if connected?(socket) do
      case socket.assigns[:subscribed_chat_id] do
        cid when is_binary(cid) ->
          Phoenix.PubSub.unsubscribe(Concilio.PubSub, "concilio:chat:" <> cid)

        _ ->
          :ok
      end
    end

    assign(socket, :subscribed_chat_id, nil)
  end

  defp pending_council_runs(messages) do
    messages
    |> Enum.flat_map(fn
      %Message{run: %Runs.Run{run_id: rid, result_json: nil} = run}
      when is_binary(rid) ->
        [run]

      %Message{run: %Runs.Run{status: status} = run}
      when status in [:running, :pending] ->
        [run]

      _ ->
        []
    end)
  end

  defp seed_progress_from_run(%Runs.Run{} = run) do
    last = Runs.latest_event_for(run)

    status =
      case last do
        %{type: "round_started", payload_json: %{"round_name" => name, "round_idx" => idx}} ->
          "Round #{idx + 1} · #{name} starting…"

        %{type: "member_started", payload_json: %{"round_name" => round, "member_id" => mid}} ->
          "#{round} · #{mid} thinking…"

        %{type: "member_completed", payload_json: %{"round_name" => round, "member_id" => mid}} ->
          "#{round} · #{mid} done"

        %{type: "round_completed", payload_json: %{"round_name" => name}} ->
          "Round #{name} complete"

        %{type: "run_started"} ->
          "Starting council…"

        _ ->
          "Council running…"
      end

    Map.merge(default_progress(), %{status: status})
  end

  # ── Events ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("new_conversation", _params, %{assigns: %{configured?: false}} = socket) do
    {:noreply,
     socket
     |> Phoenix.LiveView.put_flash(
       :error,
       "Configure at least one provider in Settings before starting a conversation."
     )
     |> push_navigate(to: ~p"/settings/providers")}
  end

  def handle_event("new_conversation", _params, socket) do
    {:ok, conv} = Chats.create_conversation(%{})
    {:noreply, push_navigate(socket, to: ~p"/c/#{conv.id}")}
  end

  def handle_event("composer_change", %{"composer" => %{"text" => text}}, socket) do
    {:noreply, assign(socket, :composer, %{"text" => text || ""})}
  end

  def handle_event("quote_council", params, socket) do
    run_id = params["run-id"] || params["run_id"] || params["runid"]

    if is_binary(run_id) and run_id != "" do
      current = socket.assigns.composer["text"] || ""
      sep = if current == "" or String.ends_with?(current, [" ", "\n"]), do: "", else: " "
      appended = current <> sep <> CouncilRefs.token_for(run_id) <> " "

      {:noreply,
       socket
       |> assign(:composer, %{"text" => appended})
       |> push_event("concilio:set_composer", %{text: appended})}
    else
      Logger.warning("quote_council: missing run id, params=#{inspect(params)}")
      {:noreply, socket}
    end
  end

  def handle_event("send", %{"composer" => %{"text" => text}}, socket) do
    text = String.trim(text || "")

    cond do
      text == "" ->
        {:noreply, socket}

      is_nil(socket.assigns.conversation) ->
        send_in_new_conversation(socket, text)

      true ->
        send_plain(socket, socket.assigns.conversation, text)
    end
  end

  def handle_event("summon_open", _params, socket) do
    {:noreply, assign(socket, :summon_open?, true)}
  end

  def handle_event("summon_cancel", _params, socket) do
    {:noreply, assign(socket, :summon_open?, false)}
  end

  def handle_event("summon_submit", %{"summon" => params}, socket) do
    text = params |> Map.get("input", "") |> String.trim()
    template_id = Map.get(params, "template_id", "")
    context = params |> Map.get("context", "") |> String.trim()
    include_history? = Map.get(params, "include_history", "true") in ["true", "on", true]

    history_limit =
      case Integer.parse(Map.get(params, "history_limit", "10")) do
        {n, _} when n > 0 and n <= 200 -> n
        _ -> 10
      end

    cond do
      text == "" ->
        {:noreply, put_flash(socket, :error, "Input can't be empty.")}

      template_id in [nil, ""] ->
        {:noreply, put_flash(socket, :error, "Pick a council.")}

      true ->
        do_summon(socket, template_id, text,
          context: context,
          include_history?: include_history?,
          history_limit: history_limit
        )
    end
  end

  def handle_event("set_model", %{"conversation" => %{"default_model" => label}}, socket) do
    case socket.assigns.conversation do
      nil ->
        {:noreply, socket}

      conv ->
        cond do
          label in [nil, ""] ->
            {:noreply, socket}

          label == conv.default_model ->
            {:noreply, socket}

          not valid_model_label?(label, socket.assigns.working_set_models, conv.default_model) ->
            {:noreply, put_flash(socket, :error, "Unknown model.")}

          true ->
            case Chats.update_conversation(conv, %{
                   default_model: label,
                   default_responder_kind: :model
                 }) do
              {:ok, updated} ->
                {:noreply, assign(socket, :conversation, updated)}

              {:error, _changeset} ->
                {:noreply, put_flash(socket, :error, "Could not save model.")}
            end
        end
    end
  end

  def handle_event("edit_title", _params, socket) do
    case socket.assigns.conversation do
      nil ->
        {:noreply, socket}

      conv ->
        {:noreply,
         socket
         |> assign(:editing_title?, true)
         |> assign(:title_draft, conv.title || "")}
    end
  end

  def handle_event("title_change", %{"title" => %{"value" => value}}, socket) do
    {:noreply, assign(socket, :title_draft, value || "")}
  end

  def handle_event("cancel_title", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_title?, false)
     |> assign(:title_draft, "")}
  end

  def handle_event("save_title", params, socket) do
    raw =
      case params do
        %{"title" => %{"value" => v}} -> v
        _ -> socket.assigns.title_draft
      end

    new_title =
      case raw |> to_string() |> String.trim() do
        "" -> nil
        s -> s
      end

    case socket.assigns.conversation do
      nil ->
        {:noreply, socket}

      conv ->
        case Chats.update_conversation(conv, %{title: new_title}) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:conversation, updated)
             |> assign(:conversations, Chats.list_conversations(limit: 50))
             |> assign(:editing_title?, false)
             |> assign(:title_draft, "")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not save title.")}
        end
    end
  end

  def handle_event("delete_conversation", _params, socket) do
    case socket.assigns.conversation do
      nil ->
        {:noreply, socket}

      conv ->
        {:ok, _} = Chats.soft_delete_conversation(conv)
        {:noreply, push_navigate(socket, to: ~p"/")}
    end
  end

  defp send_in_new_conversation(socket, text) do
    case default_responder() do
      {:ok, provider, model} ->
        {:ok, conv} =
          Chats.create_conversation(%{
            default_responder_kind: :model,
            default_model: model_label(provider, model)
          })

        send_plain(socket, conv, text)

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Configure a provider in Settings before chatting.")}
    end
  end

  defp send_plain(socket, conv, text) do
    case resolve_responder(conv) do
      {:ok, provider, model} ->
        {:ok, _user_msg} = Chats.append_user_message(conv, text)
        history = build_history(Chats.list_messages(conv.id))
        label = model_label(provider, model)

        case Chats.start_plain_assistant(conv, label) do
          {:ok, pending_msg} ->
            {:ok, _pid} =
              Concilio.Chats.PlainCompletionWorker.start(
                pending_msg.id,
                provider,
                model,
                history
              )

            socket = ensure_chat_subscription(socket, conv)

            {:noreply,
             socket
             |> assign(:conversation, conv)
             |> assign(:messages, Chats.list_messages(conv.id))
             |> assign(:composer, %{"text" => ""})
             |> push_event("concilio:set_composer", %{text: ""})
             |> push_event("concilio:scroll_to_bottom", %{})}

          {:error, reason} ->
            Logger.error("plain placeholder insert failed: #{inspect(reason)}")

            {:noreply,
             socket
             |> put_flash(:error, "Could not start completion.")
             |> assign(:composer, %{"text" => text})}
        end

      {:error, reason} ->
        Logger.error("chat send failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Could not send: #{format_reason(reason)}")
         |> assign(:composer, %{"text" => text})}
    end
  end

  defp ensure_chat_subscription(socket, conv) do
    if connected?(socket) and socket.assigns[:subscribed_chat_id] != conv.id do
      socket = unsubscribe_chat(socket)
      Phoenix.PubSub.subscribe(Concilio.PubSub, "concilio:chat:" <> conv.id)
      assign(socket, :subscribed_chat_id, conv.id)
    else
      socket
    end
  end

  defp build_council_input(text, history, context) do
    base = %{question: text}
    base = if history == [], do: base, else: Map.put(base, :history, history)
    base = if context in [nil, ""], do: base, else: Map.put(base, :context, context)
    base
  end

  defp build_history(messages), do: History.build(messages)

  defp resolve_responder(conv) do
    case conv.default_model do
      nil ->
        default_responder()

      label when is_binary(label) ->
        case parse_model_label(label) do
          {:ok, _, _} = ok -> ok
          :error -> default_responder()
        end
    end
  end

  defp default_responder do
    case Concilio.Providers.list_working_set_models() do
      [%{provider: p, model_id: m} | _] -> {:ok, p, m}
      [] -> {:error, :no_working_set}
    end
  end

  defp model_label(provider, model_id), do: "#{provider}:#{model_id}"

  defp valid_model_label?(label, working_set, current_label) do
    label == current_label or
      Enum.any?(working_set, &(model_label(&1.provider, &1.model_id) == label))
  end

  defp parse_model_label(label) do
    case String.split(label, ":", parts: 2) do
      [provider_str, model_id] ->
        try do
          {:ok, String.to_existing_atom(provider_str), model_id}
        rescue
          ArgumentError -> :error
        end

      _ ->
        :error
    end
  end

  defp format_reason(:no_working_set), do: "no models in any working set"

  defp do_summon(socket, template_id, text, opts) do
    template = Councils.get!(template_id)
    context = Keyword.get(opts, :context, "")
    include_history? = Keyword.get(opts, :include_history?, true)
    history_limit = Keyword.get(opts, :history_limit, 10)

    conv =
      case socket.assigns.conversation do
        nil ->
          {:ok, c} =
            Chats.create_conversation(%{
              default_responder_kind: :council,
              default_template_id: template.id
            })

          c

        existing ->
          existing
      end

    history =
      if include_history? do
        conv.id
        |> Chats.list_messages()
        |> Enum.take(-history_limit)
        |> build_history()
      else
        []
      end

    {:ok, _user_msg} = Chats.append_user_message(conv, text)

    payload = build_council_input(CouncilRefs.expand(text), history, context)

    case RunStarter.start(template, payload) do
      {:ok, run} ->
        version_id = run.template_version_id

        {:ok, _msg} =
          Chats.append_council_assistant(conv, %{
            run_id: run.id,
            template_id: template.id,
            template_version_id: version_id
          })

        # Subscribe so the LV can refresh on completion.
        Phoenix.PubSub.subscribe(Concilio.PubSub, "council_ex:run:#{run.run_id}")

        new_conv? = is_nil(socket.assigns.conversation)

        subscribed = (socket.assigns[:subscribed_run_ids] || []) ++ [run.run_id]

        socket =
          socket
          |> assign(:summon_open?, false)
          |> assign(:active_run_id, run.run_id)
          |> assign(:conversation, conv)
          |> assign(:messages, Chats.list_messages(conv.id))
          |> assign(:subscribed_run_ids, subscribed)
          |> assign(
            :run_progress,
            Map.put(socket.assigns.run_progress || %{}, run.run_id, default_progress())
          )
          |> assign(:composer, %{"text" => ""})
          |> push_event("concilio:scroll_to_bottom", %{})

        if new_conv? do
          {:noreply, push_navigate(socket, to: ~p"/c/#{conv.id}")}
        else
          {:noreply, socket}
        end

      {:error, reason} ->
        Logger.error("council summon failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Council summon failed: #{inspect(reason)}")
         |> assign(:summon_open?, false)}
    end
  end

  # ── PubSub ──────────────────────────────────────────────────────────

  @impl true
  def handle_info({:run_started, run_id, _council, _input}, socket) do
    {:noreply, set_progress(socket, run_id, %{phase: :starting, status: "Starting council…"})}
  end

  def handle_info({:round_started, run_id, round_name, idx}, socket) do
    {:noreply,
     update_progress(socket, run_id, %{
       phase: :round,
       round_idx: idx,
       round_name: to_string(round_name),
       status: "Round #{idx + 1} · #{round_name} starting…"
     })}
  end

  def handle_info({:member_started, run_id, round_name, member_id}, socket) do
    {:noreply,
     update_progress(socket, run_id, %{
       phase: :member,
       round_name: to_string(round_name),
       member_id: to_string(member_id),
       status: "#{round_name} · #{member_id} thinking…"
     })}
  end

  def handle_info({:member_completed, run_id, round_name, member_id, _result}, socket) do
    {:noreply,
     update_progress(socket, run_id, %{
       status: "#{round_name} · #{member_id} done"
     })}
  end

  def handle_info({:round_completed, run_id, round_name, _round_result}, socket) do
    {:noreply, update_progress(socket, run_id, %{status: "Round #{round_name} complete"})}
  end

  # CouncilEx terminal events: just update progress text. Wait for the
  # post-finalize broadcast before refreshing messages, otherwise the DB
  # row may not have `result_json` yet (race against `Runs.finalize!`).
  def handle_info({:run_completed, run_id, _result}, socket) do
    {:noreply, update_progress(socket, run_id, %{status: "Synthesizing final answer…"})}
  end

  def handle_info({:run_failed, run_id, _error}, socket) do
    {:noreply, update_progress(socket, run_id, %{status: "Run failed"})}
  end

  def handle_info({:run_cancelled, run_id}, socket) do
    {:noreply, update_progress(socket, run_id, %{status: "Run cancelled"})}
  end

  # Recorder-emitted, post-finalize. Safe to refresh now.
  def handle_info({:concilio_finalized, run_id}, socket) do
    socket
    |> clear_council_pending(run_id)
    |> refresh_messages()
  end

  # PlainCompletionWorker-emitted, post-update. Refresh the message list
  # so the placeholder bubble swaps to the actual content (or error).
  def handle_info({:plain_message_updated, _message_id}, socket) do
    refresh_messages(socket)
  end

  # CouncilEx token chunks + tool calls + anything else: ignore.
  def handle_info(_other, socket), do: {:noreply, socket}

  defp clear_council_pending(socket, run_id) do
    progress = Map.delete(socket.assigns.run_progress || %{}, run_id)

    socket
    |> assign(:run_progress, progress)
    |> assign(:active_run_id, nil)
  end

  defp set_progress(socket, run_id, attrs) when is_binary(run_id) do
    progress =
      Map.put(socket.assigns.run_progress || %{}, run_id, Map.merge(default_progress(), attrs))

    assign(socket, :run_progress, progress)
  end

  defp set_progress(socket, _run_id, _attrs), do: socket

  defp update_progress(socket, run_id, attrs) when is_binary(run_id) do
    current = socket.assigns.run_progress || %{}
    existing = Map.get(current, run_id, default_progress())
    progress = Map.put(current, run_id, Map.merge(existing, attrs))
    assign(socket, :run_progress, progress)
  end

  defp update_progress(socket, _run_id, _attrs), do: socket

  defp default_progress do
    %{phase: :starting, status: "Waiting…", round_idx: nil, round_name: nil, member_id: nil}
  end

  defp refresh_messages(socket) do
    case socket.assigns.conversation do
      nil ->
        {:noreply, socket}

      conv ->
        {:noreply, assign(socket, :messages, Chats.list_messages(conv.id))}
    end
  end

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} max_w="max-w-7xl">
      <div class="flex gap-6 h-[calc(100dvh-8rem)]">
        <.sidebar
          :if={@configured?}
          conversations={@conversations}
          active={@conversation}
          working_set_models={@working_set_models}
        />

        <div class="flex flex-col gap-4 min-w-0 h-full flex-1">
          <%= cond do %>
            <% not @configured? -> %>
              <.onboarding_card />
            <% is_nil(@conversation) -> %>
              <.empty_chat_state />
            <% true -> %>
              <.thread_header
                conversation={@conversation}
                editing?={@editing_title?}
                draft={@title_draft}
              />

              <div
                id="chat-scroll"
                phx-hook="AutoScroll"
                class="flex-1 overflow-y-auto min-h-0 pr-1"
              >
                <.thread messages={@messages} run_progress={@run_progress} />
              </div>

              <.composer
                form_data={@composer}
                can_summon?={@templates != []}
                conversation={@conversation}
                working_set_models={@working_set_models}
              />
          <% end %>
        </div>
      </div>

      <%= if @summon_open? do %>
        <.summon_modal templates={@templates} form={@summon_form} />
      <% end %>
    </Layouts.app>
    """
  end

  defp onboarding_card(assigns) do
    ~H"""
    <div class="hero bg-base-200 rounded-box flex-1">
      <div class="hero-content text-center max-w-xl">
        <div class="space-y-4">
          <h1 class="text-3xl font-semibold">Welcome to Concilio</h1>

          <p class="text-base-content/70">
            Concilio needs at least one LLM provider before you can chat or run councils.
          </p>

          <p class="text-sm text-base-content/60">
            <strong>Quickest path:</strong>
            OpenRouter gives you access to dozens of models with a single API key.
          </p>

          <.link navigate={~p"/settings/providers"} class="btn btn-primary">
            Set up a provider →
          </.link>

          <p class="text-xs text-base-content/40">
            You can also pick OpenAI, Anthropic, Gemini, OpenRouter, or run Ollama locally.
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp empty_chat_state(assigns) do
    ~H"""
    <div class="hero bg-base-200/40 rounded-box flex-1">
      <div class="hero-content text-center max-w-md">
        <div class="space-y-4">
          <div class="flex justify-center">
            <span class="hero-chat-bubble-left-right size-12 text-base-content/40"></span>
          </div>

          <h1 class="text-2xl font-semibold">Start a new conversation</h1>

          <p class="text-base-content/60">
            Pick a model and chat directly, or summon a council to deliberate.
          </p>

          <button class="btn btn-primary" phx-click="new_conversation">
            + New conversation
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :conversations, :list, required: true
  attr :active, :any, required: true
  attr :working_set_models, :list, default: []

  defp sidebar(assigns) do
    ready = MapSet.new(assigns.working_set_models, & &1.provider)

    rows =
      Enum.map(assigns.conversations, fn conv ->
        {ready?, missing} = conversation_provider_status(conv, ready)
        %{conv: conv, ready?: ready?, missing: missing}
      end)

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <aside class="card bg-base-100 border border-base-300 w-72 shrink-0 hidden md:flex h-full overflow-hidden">
      <div class="card-body p-3 gap-2 flex flex-col min-h-0">
        <button
          class="btn btn-primary btn-sm w-full shrink-0"
          phx-click="new_conversation"
          title="Start a new conversation"
        >
          + New conversation
        </button>

        <ul class="menu menu-sm flex-1 overflow-y-auto min-h-0 flex-nowrap">
          <li :for={row <- @rows}>
            <.link
              :if={row.ready?}
              navigate={~p"/c/#{row.conv.id}"}
              class={[
                "truncate",
                @active && @active.id == row.conv.id && "active"
              ]}
            >
              {display_title(row.conv)}
            </.link>

            <span
              :if={not row.ready?}
              class="tooltip tooltip-right flex items-center gap-1 truncate opacity-50 cursor-not-allowed"
              data-tip={"Enable #{row.missing} in Settings to open this conversation"}
            >
              <span class="truncate">{display_title(row.conv)}</span>
              <.icon name="hero-exclamation-triangle" class="size-4 text-warning shrink-0" />
            </span>
          </li>

          <li :if={@conversations == []} class="text-xs text-base-content/50 px-2 py-2">
            No conversations yet.
          </li>
        </ul>
      </div>
    </aside>
    """
  end

  # A conversation is openable when it pins no specific provider (council
  # turns, or a brand-new chat with no default model) or when the provider
  # behind its `default_model` has a model in the working set. Returns
  # `{ready?, missing_provider}` — `missing_provider` is nil when ready.
  defp conversation_provider_status(conv, ready_providers) do
    case required_provider(conv) do
      nil -> {true, nil}
      provider -> {MapSet.member?(ready_providers, provider), provider}
    end
  end

  defp required_provider(%{default_responder_kind: :model, default_model: model})
       when is_binary(model) do
    case parse_model_label(model) do
      {:ok, provider, _model_id} -> provider
      :error -> nil
    end
  end

  defp required_provider(_), do: nil

  attr :conversation, :any, required: true
  attr :editing?, :boolean, default: false
  attr :draft, :string, default: ""

  defp thread_header(%{conversation: nil} = assigns) do
    ~H"""
    <h1 class="text-2xl font-semibold">Start a conversation</h1>
    """
  end

  defp thread_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3 min-h-[2.5rem]">
      <%= if @editing? do %>
        <form
          phx-submit="save_title"
          phx-change="title_change"
          class="flex items-center gap-2 flex-1 min-w-0"
        >
          <input
            type="text"
            name="title[value]"
            value={@draft}
            phx-mounted={Phoenix.LiveView.JS.focus()}
            class="input input-sm input-bordered flex-1 min-w-0"
            placeholder="Conversation title"
            maxlength="200"
            phx-key="Escape"
            phx-keydown="cancel_title"
          />
          <button type="submit" class="btn btn-primary btn-sm">Save</button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_title">
            Cancel
          </button>
        </form>
      <% else %>
        <button
          type="button"
          phx-click="edit_title"
          class="text-2xl font-semibold text-left truncate hover:underline decoration-base-content/30 underline-offset-4 cursor-pointer"
          title="Click to rename"
        >
          {display_title(@conversation)}
        </button>

        <button
          class="btn btn-ghost btn-xs"
          phx-click="delete_conversation"
          data-confirm="Delete conversation?"
        >
          Delete
        </button>
      <% end %>
    </div>
    """
  end

  defp display_title(%{title: t}) when is_binary(t) and t != "", do: t

  defp display_title(%{inserted_at: %DateTime{} = at}) do
    "New chat · " <> Calendar.strftime(at, "%b %-d, %H:%M")
  end

  defp display_title(_), do: "New chat"

  defp group_models_by_provider(models) do
    models
    |> Enum.group_by(& &1.provider)
    |> Enum.sort_by(fn {provider, _} -> Atom.to_string(provider) end)
    |> Enum.map(fn {provider, ms} ->
      {provider, Enum.sort_by(ms, & &1.model_id)}
    end)
  end

  attr :messages, :list, required: true
  attr :run_progress, :map, default: %{}

  defp thread(assigns) do
    assigns = assign(assigns, :rows, messages_with_durations(assigns.messages))

    ~H"""
    <div class="space-y-3">
      <div :if={@messages == []} class="text-base-content/60 text-sm">
        No messages yet. Type below to start.
      </div>

      <%= for {msg, duration_ms} <- @rows do %>
        <.message_row msg={msg} duration_ms={duration_ms} run_progress={@run_progress} />
      <% end %>
    </div>
    """
  end

  attr :msg, :map, required: true
  attr :duration_ms, :integer, default: nil
  attr :run_progress, :map, default: %{}

  defp message_row(%{msg: %Message{role: :user}} = assigns) do
    ~H"""
    <div class="chat chat-end">
      <div class="chat-bubble chat-bubble-primary whitespace-pre-wrap">{@msg.content}</div>
    </div>
    """
  end

  defp message_row(%{msg: msg} = assigns) do
    council? = Message.council_turn?(msg)
    plain_pending? = Message.plain_turn?(msg) and Message.pending?(msg)
    council_pending? = council? and council_pending?(msg)
    pending? = plain_pending? or council_pending?

    progress = if council_pending?, do: lookup_progress(msg, assigns.run_progress), else: nil
    body = if council? and not council_pending?, do: council_body(msg), else: msg.content
    started_at_ms = message_started_at_ms(msg)

    assigns =
      assign(assigns,
        council?: council?,
        plain_pending?: plain_pending?,
        council_pending?: council_pending?,
        pending?: pending?,
        progress: progress,
        body: body,
        started_at_ms: started_at_ms
      )

    ~H"""
    <div class="chat chat-start">
      <div class="chat-header text-xs font-mono text-base-content/60 mb-1">
        <%= if @council? do %>
          Council ·
          <.link navigate={~p"/runs/#{@msg.run_id}"} class="link link-hover">view run</.link>
          ·
          <button
            type="button"
            phx-click="quote_council"
            phx-value-run-id={@msg.run_id}
            class="link link-hover"
            title="Insert a reference to this council result in your reply"
          >
            quote in reply
          </button>
        <% else %>
          {@msg.model_used || "model"}
        <% end %>
        <span :if={@pending? and @started_at_ms} class="ml-1 text-base-content/50">
          ·
          <span
            id={"elapsed-" <> @msg.id}
            phx-hook="ElapsedTimer"
            phx-update="ignore"
            data-start-ms={@started_at_ms}
          >
            0.0s
          </span>
        </span>
        <span :if={not @pending? and @duration_ms} class="ml-1 text-base-content/50">
          · {format_duration_ms(@duration_ms)}
        </span>
      </div>
      <div class={[
        "chat-bubble bg-base-100 text-base-content border border-base-300",
        @msg.status == :error && "border-error text-error"
      ]}>
        <%= cond do %>
          <% @council_pending? -> %>
            <.council_progress progress={@progress} />
          <% @plain_pending? -> %>
            <.plain_pending_indicator />
          <% true -> %>
            <.markdown body={@body} />
        <% end %>
      </div>
    </div>
    """
  end

  defp plain_pending_indicator(assigns) do
    ~H"""
    <span class="loading loading-dots loading-sm"></span>
    """
  end

  defp message_started_at_ms(%Message{run: %Runs.Run{started_at: %DateTime{} = dt}}),
    do: DateTime.to_unix(dt, :millisecond)

  defp message_started_at_ms(%Message{inserted_at: %DateTime{} = dt}),
    do: DateTime.to_unix(dt, :millisecond)

  defp message_started_at_ms(_), do: nil

  attr :progress, :map, default: nil

  defp council_progress(assigns) do
    status =
      case assigns.progress do
        %{status: s} when is_binary(s) and s != "" -> s
        _ -> "Council running…"
      end

    assigns = assign(assigns, :status_text, status)

    ~H"""
    <div class="space-y-2 min-w-[16rem]">
      <div class="flex items-center gap-2 text-sm">
        <span class="loading loading-spinner loading-xs"></span>
        <span class="italic">{@status_text}</span>
      </div>
      <progress class="progress progress-primary w-full h-1.5"></progress>
    </div>
    """
  end

  defp council_pending?(%Message{run: %Runs.Run{status: status}})
       when status in [:running, nil],
       do: true

  defp council_pending?(%Message{run: %{result_json: nil}}), do: true
  defp council_pending?(_), do: false

  defp lookup_progress(%Message{run: %Runs.Run{run_id: rid}}, progress)
       when is_binary(rid) and is_map(progress),
       do: Map.get(progress, rid)

  defp lookup_progress(_, _), do: nil

  defp messages_with_durations(messages) do
    {rows, _last_user_at} =
      Enum.map_reduce(messages, nil, fn msg, last_user_at ->
        case msg.role do
          :user ->
            {{msg, nil}, msg.inserted_at}

          :assistant ->
            duration =
              cond do
                Message.council_turn?(msg) -> run_duration_ms(msg.run)
                last_user_at -> DateTime.diff(msg.inserted_at, last_user_at, :millisecond)
                true -> nil
              end

            {{msg, duration}, last_user_at}

          _ ->
            {{msg, nil}, last_user_at}
        end
      end)

    rows
  end

  defp run_duration_ms(%Runs.Run{started_at: %DateTime{} = s, finished_at: %DateTime{} = f}),
    do: DateTime.diff(f, s, :millisecond)

  defp run_duration_ms(_), do: nil

  defp format_duration_ms(nil), do: nil

  defp format_duration_ms(ms) when ms < 60_000 do
    :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"
  end

  defp format_duration_ms(ms) do
    s = div(ms, 1000)
    m = div(s, 60)
    rest = rem(s, 60)
    "#{m}m #{rest}s"
  end

  defp council_body(%Message{run: %{result_json: %{} = result}}) do
    case Map.get(result, "final") do
      %{"content" => content} when is_binary(content) -> content
      _ -> "_(council still running…)_"
    end
  end

  defp council_body(%Message{run: %Runs.Run{status: status}})
       when status in [:running, nil],
       do: "_(council running…)_"

  defp council_body(%Message{run: %Runs.Run{status: :stuck}}),
    do: "_Lost: server restarted before the council finished. Send again._"

  defp council_body(%Message{run: %Runs.Run{status: :error}}),
    do: "_The council run failed._"

  defp council_body(%Message{run: %Runs.Run{status: :cancelled}}),
    do: "_The council run was cancelled._"

  defp council_body(_), do: "_(no result)_"

  attr :form_data, :map, required: true
  attr :can_summon?, :boolean, required: true
  attr :conversation, :any, default: nil
  attr :working_set_models, :list, default: []

  defp composer(assigns) do
    selected = if assigns.conversation, do: assigns.conversation.default_model
    grouped = group_models_by_provider(assigns.working_set_models)

    in_set? =
      selected &&
        Enum.any?(
          assigns.working_set_models,
          &(model_label(&1.provider, &1.model_id) == selected)
        )

    assigns =
      assigns
      |> assign(:selected_label, selected)
      |> assign(:grouped_models, grouped)
      |> assign(:stale?, selected && not in_set?)

    ~H"""
    <form
      id="composer-form"
      phx-submit="send"
      phx-change="composer_change"
      class="card bg-base-100 border border-base-300"
    >
      <div class="card-body p-3 space-y-2">
        <textarea
          id="composer-text"
          name="composer[text]"
          rows="3"
          class="textarea textarea-bordered w-full"
          placeholder="Type a message… (Enter to send, Shift+Enter for newline)"
          phx-hook="ComposerKeys"
        ><%= @form_data["text"] %></textarea>

        <div class="flex justify-between items-center gap-2">
          <div class="flex items-center gap-2 min-w-0">
            <%= if @grouped_models == [] do %>
              <span class="text-xs text-base-content/60">
                No models.
                <.link navigate={~p"/settings/providers"} class="link link-hover">Configure →</.link>
              </span>
            <% else %>
              <label class="form-control min-w-0">
                <span class="sr-only">Model for next message</span>
                <select
                  name="conversation[default_model]"
                  class="select select-sm select-bordered max-w-[16rem]"
                  aria-label="Model for next message"
                  phx-change="set_model"
                  disabled={is_nil(@conversation)}
                >
                  <option :if={is_nil(@selected_label)} value="" selected>Pick a model…</option>
                  <option :if={@stale?} value={@selected_label} selected>
                    {@selected_label} (not in working set)
                  </option>

                  <optgroup
                    :for={{provider, models} <- @grouped_models}
                    label={Atom.to_string(provider)}
                  >
                    <option
                      :for={m <- models}
                      value={model_label(m.provider, m.model_id)}
                      selected={model_label(m.provider, m.model_id) == @selected_label}
                    >
                      {m.model_id}
                    </option>
                  </optgroup>
                </select>
              </label>
            <% end %>

            <button
              type="button"
              class="btn btn-secondary btn-outline btn-sm"
              phx-click="summon_open"
              disabled={!@can_summon?}
            >
              + Summon council
            </button>
          </div>

          <button type="submit" class="btn btn-primary btn-sm">Send</button>
        </div>
      </div>
    </form>
    """
  end

  attr :templates, :list, required: true
  attr :form, :map, required: true

  defp summon_modal(assigns) do
    ~H"""
    <dialog class="modal modal-open">
      <div class="modal-box max-w-lg">
        <h3 class="text-lg font-semibold">Summon council</h3>
        <p class="text-sm text-base-content/60 mt-1">
          Pick a template and a question for the council to deliberate on.
        </p>

        <.form for={@form} phx-submit="summon_submit" class="space-y-4 mt-4">
          <fieldset class="fieldset">
            <legend class="fieldset-legend">Council</legend>
            <select name="summon[template_id]" class="select w-full" required>
              <option value="" disabled selected>Pick a template…</option>
              <option :for={t <- @templates} value={t.id}>{t.name}</option>
            </select>
          </fieldset>

          <fieldset class="fieldset">
            <legend class="fieldset-legend">Input</legend>
            <textarea
              name="summon[input]"
              class="textarea w-full"
              rows="5"
              placeholder="What should the council deliberate on?"
              required
            ></textarea>
          </fieldset>

          <fieldset class="fieldset">
            <legend class="fieldset-legend">Conversation history</legend>
            <label class="label cursor-pointer gap-2 py-1 justify-start">
              <input
                type="checkbox"
                name="summon[include_history]"
                value="true"
                class="checkbox checkbox-sm"
                checked
              />
              <span class="label-text">Include last</span>
              <input
                type="number"
                name="summon[history_limit]"
                value="10"
                min="1"
                max="200"
                class="input input-sm input-bordered w-20"
              />
              <span class="label-text">messages as context</span>
            </label>
          </fieldset>

          <fieldset class="fieldset">
            <legend class="fieldset-legend">Extra context (optional)</legend>
            <textarea
              name="summon[context]"
              class="textarea w-full"
              rows="3"
              placeholder="Additional background, constraints, or facts."
            ></textarea>
          </fieldset>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="summon_cancel">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">Summon</button>
          </div>
        </.form>
      </div>
    </dialog>
    """
  end

  defp summon_form, do: to_form(%{"template_id" => "", "input" => ""}, as: :summon)
end
