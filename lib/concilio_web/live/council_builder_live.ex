defmodule ConcilioWeb.CouncilBuilderLive do
  @moduledoc """
  Dynamic council builder: name, members (list), chairman, rounds.
  Save creates a new immutable `council_template_versions` row.

  Members and chair are flat string-keyed maps (`id`, `role`, `provider`,
  `model`, `system_prompt`, plus optional `temperature` / `max_tokens`
  numerics that `RunStarter` lifts into `profile_overrides` at runtime).
  Rounds are a list of `%{"type" => name, "opts" => map}` maps. The
  whole list-shaped JSON is persisted as-is on
  `template_versions.spec_json` (RunStarter hydrates it back into a
  `CouncilEx.DynamicCouncil` at run time).
  """

  use ConcilioWeb, :live_view

  alias Concilio.Councils
  alias Concilio.Councils.Prebuilt
  alias Concilio.Providers

  # CouncilEx builtin round types — kept in sync with
  # `CouncilEx.__builtin_rounds__/0` (council_ex.ex).
  @round_types [
    "independent_analysis",
    "synthesis",
    "peer_review",
    "anonymized_peer_review",
    "critique",
    "ranking",
    "vote",
    "iterate",
    "pairwise_elimination"
  ]

  # Subset of `CouncilEx.Profile.__valid_keys__/0` exposed as numeric
  # inputs. Provider/model live as their own fields; the rest of the
  # whitelisted opts (`stream`, `retry`, `tools`, …) need richer UI and
  # come in a later phase.
  @override_numeric_keys ["temperature", "max_tokens"]

  @impl true
  def mount(params, _session, socket) do
    {mode, template, prebuilt} =
      case {params["id"], params["prebuilt"]} do
        {nil, nil} -> {:new, nil, nil}
        {nil, slug} -> {:new, nil, Prebuilt.get(slug)}
        {id, _} -> {:edit, Councils.get!(id), nil}
      end

    spec = current_spec(template, prebuilt)

    socket =
      socket
      |> assign(:page_title, page_title_for(mode, template))
      |> assign(:mode, mode)
      |> assign(:template, template)
      |> assign(:prebuilt, prebuilt)
      |> assign(:working_set, Providers.list_working_set_models())
      |> assign(:round_types, @round_types)
      |> assign(:registered_profiles, CouncilEx.Registry.list(:profile))
      |> assign(:registered_routers, CouncilEx.Registry.list(:router))
      |> assign(:registered_tools, CouncilEx.Registry.list(:tool))
      |> assign(:registered_schemas, CouncilEx.Registry.list(:schema))
      |> assign(:registered_sub_councils, CouncilEx.Registry.list(:sub_council))
      |> assign(:registered_input_mappers, CouncilEx.Registry.list(:input_mapper))
      |> assign(:static_templates, list_static_template_options(template))
      |> assign(:form, builder_form(template, prebuilt))
      |> assign(:members, normalize_member_list(Map.get(spec, "members", [])))
      |> assign(
        :chairman,
        normalize_chair_map(spec["chairman"] || spec["chair"] || default_chair())
      )
      |> assign(:rounds, normalize_round_list(Map.get(spec, "rounds", default_rounds())))
      |> assign(:default_profile, Map.get(spec, "default_profile"))
      |> assign(:router, Map.get(spec, "router"))
      |> assign(:council_tools, normalize_string_list(Map.get(spec, "tools", [])))
      |> assign(:metadata_json, metadata_to_json(Map.get(spec, "metadata")))
      |> assign(:errors, [])

    {:ok, recompute_diagram(socket)}
  end

  defp page_title_for(:new, _), do: "New council"
  defp page_title_for(:edit, t), do: "Edit #{t.name}"

  defp current_spec(nil, nil), do: %{}

  defp current_spec(nil, %{} = prebuilt) do
    chair =
      default_chair()
      |> Map.put("system_prompt", prebuilt.chair_prompt)

    members =
      1..prebuilt.suggested_members
      |> Enum.map(&new_member/1)

    %{
      "rounds" => prebuilt.rounds,
      "chairman" => chair,
      "members" => members
    }
  end

  defp current_spec(%{current_version: %{spec_json: spec}}, _) when is_map(spec),
    do: Concilio.Councils.static_to_dynamic_spec(spec)

  defp current_spec(_, _), do: %{}

  defp default_chair do
    %{
      "id" => "chair",
      "role" => nil,
      "provider" => nil,
      "model" => nil,
      "system_prompt" => "Synthesize.",
      "temperature" => nil,
      "max_tokens" => nil,
      "profile" => nil,
      "tools" => [],
      "output_schema" => nil,
      "output_schema_inline" => nil,
      "sub_council_kind" => "none",
      "sub_council_ref" => nil,
      "input_mapper" => nil
    }
  end

  defp list_static_template_options(current) do
    Concilio.Councils.list_templates(kind: :static)
    |> Enum.reject(fn t -> current && t.id == current.id end)
    |> Enum.map(fn t -> %{name: t.name, module: t.source_module} end)
    |> Enum.reject(fn t -> is_nil(t.module) end)
  end

  defp metadata_to_json(nil), do: ""
  defp metadata_to_json(map) when map == %{}, do: ""
  defp metadata_to_json(map) when is_map(map), do: Jason.encode!(map)
  defp metadata_to_json(_), do: ""

  defp default_rounds, do: [%{"type" => "independent_analysis", "opts" => %{}}]

  defp builder_form(template, prebuilt) do
    base = %{
      "name" => (template && template.name) || (prebuilt && prebuilt.name) || "",
      "description" =>
        (template && template.description) || (prebuilt && prebuilt.description) || ""
    }

    to_form(base, as: :builder)
  end

  # ── Events ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("add_member", _params, socket) do
    members = socket.assigns.members ++ [new_member(length(socket.assigns.members) + 1)]

    {:noreply,
     socket
     |> assign(:members, members)
     |> recompute_diagram()}
  end

  def handle_event("remove_member", %{"index" => idx}, socket) do
    idx = String.to_integer(idx)
    members = List.delete_at(socket.assigns.members, idx)

    {:noreply,
     socket
     |> assign(:members, members)
     |> recompute_diagram()}
  end

  def handle_event("add_round", _params, socket) do
    rounds = socket.assigns.rounds ++ [%{"type" => "peer_review", "opts" => %{}}]

    {:noreply,
     socket
     |> assign(:rounds, rounds)
     |> recompute_diagram()}
  end

  def handle_event("remove_round", %{"index" => idx}, socket) do
    idx = String.to_integer(idx)
    rounds = List.delete_at(socket.assigns.rounds, idx)

    {:noreply,
     socket
     |> assign(:rounds, rounds)
     |> recompute_diagram()}
  end

  def handle_event("move_round_up", %{"index" => idx}, socket) do
    idx = String.to_integer(idx)
    rounds = swap(socket.assigns.rounds, idx, idx - 1)

    {:noreply,
     socket
     |> assign(:rounds, rounds)
     |> recompute_diagram()}
  end

  def handle_event("move_round_down", %{"index" => idx}, socket) do
    idx = String.to_integer(idx)
    rounds = swap(socket.assigns.rounds, idx, idx + 1)

    {:noreply,
     socket
     |> assign(:rounds, rounds)
     |> recompute_diagram()}
  end

  def handle_event("form_change", params, socket) do
    members = merge_members(socket.assigns.members, params["members"])

    chairman =
      Map.merge(socket.assigns.chairman, normalize_member_patch(params["chairman"] || %{}))

    rounds = merge_rounds(socket.assigns.rounds, params["rounds"])

    council = params["council"] || %{}
    default_profile = blank_to_nil(Map.get(council, "default_profile"))
    router = blank_to_nil(Map.get(council, "router"))
    council_tools = normalize_string_list(Map.get(council, "tools", []))
    metadata_json = Map.get(council, "metadata_json", socket.assigns.metadata_json)

    {:noreply,
     socket
     |> assign(:members, members)
     |> assign(:chairman, chairman)
     |> assign(:rounds, rounds)
     |> assign(:default_profile, default_profile)
     |> assign(:router, router)
     |> assign(:council_tools, council_tools)
     |> assign(:metadata_json, metadata_json)
     |> recompute_diagram()}
  end

  def handle_event("save", %{"builder" => params}, socket) do
    members_persisted = Enum.map(socket.assigns.members, &materialize_member/1)
    chair_persisted = materialize_member(socket.assigns.chairman)

    spec =
      %{
        "members" => members_persisted,
        "chairman" => chair_persisted,
        "rounds" => socket.assigns.rounds
      }
      |> maybe_put_spec("default_profile", socket.assigns.default_profile)
      |> maybe_put_spec("router", socket.assigns.router)
      |> maybe_put_spec("tools", socket.assigns.council_tools)
      |> maybe_put_spec("metadata", parse_json_object(socket.assigns.metadata_json))

    case socket.assigns.mode do
      :new ->
        attrs = %{
          name: params["name"],
          description: params["description"],
          spec: spec
        }

        case Councils.create_dynamic_template(attrs) do
          {:ok, template} ->
            {:noreply,
             socket
             |> put_flash(:info, "Created.")
             |> push_navigate(to: ~p"/councils/#{template.id}")}

          {:error, cs} ->
            {:noreply, assign(socket, :errors, format_errors(cs))}
        end

      :edit ->
        case Councils.save_new_version(socket.assigns.template, spec) do
          {:ok, template} ->
            {:noreply,
             socket
             |> put_flash(:info, "Saved as new version.")
             |> push_navigate(to: ~p"/councils/#{template.id}")}

          {:error, cs} ->
            {:noreply, assign(socket, :errors, format_errors(cs))}
        end
    end
  end

  defp format_errors(%Ecto.Changeset{errors: errs}) do
    Enum.map(errs, fn {field, {msg, _}} -> "#{field}: #{msg}" end)
  end

  defp format_errors(other), do: ["#{inspect(other)}"]

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp maybe_put_spec(spec, _k, nil), do: spec
  defp maybe_put_spec(spec, _k, ""), do: spec
  defp maybe_put_spec(spec, _k, []), do: spec
  defp maybe_put_spec(spec, _k, m) when m == %{}, do: spec
  defp maybe_put_spec(spec, k, v), do: Map.put(spec, k, v)

  # Convert in-memory member shape (with `sub_council_kind` / `sub_council_ref`
  # / `output_schema_inline` as a JSON string) into the persisted JSON shape
  # `DynamicMember.new/1` understands.
  defp materialize_member(%{} = m) do
    sub = encode_sub_council(m["sub_council_kind"], m["sub_council_ref"])
    inline = parse_json_object(m["output_schema_inline"])

    m
    |> Map.drop(["sub_council_kind", "sub_council_ref"])
    |> put_or_drop("sub_council", sub)
    |> put_or_drop("output_schema_inline", inline)
    |> put_or_drop("input_mapper", blank_to_nil(m["input_mapper"]))
  end

  defp encode_sub_council("registered", ref) when is_binary(ref) and ref != "", do: ref

  defp encode_sub_council("module", ref) when is_binary(ref) and ref != "",
    do: %{"module" => ref}

  defp encode_sub_council(_, _), do: nil

  defp put_or_drop(map, key, nil), do: Map.delete(map, key)
  defp put_or_drop(map, key, ""), do: Map.delete(map, key)
  defp put_or_drop(map, key, v), do: Map.put(map, key, v)

  defp parse_json_object(nil), do: nil
  defp parse_json_object(""), do: nil

  defp parse_json_object(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  defp parse_json_object(map) when is_map(map), do: map
  defp parse_json_object(_), do: nil

  defp merge_members(current, nil), do: current

  defp merge_members(current, patches) when is_map(patches) do
    current
    |> Enum.with_index()
    |> Enum.map(fn {member, idx} ->
      case Map.get(patches, Integer.to_string(idx)) do
        nil -> member
        patch when is_map(patch) -> Map.merge(member, normalize_member_patch(patch))
      end
    end)
  end

  defp merge_rounds(current, nil), do: current

  defp merge_rounds(current, patches) when is_map(patches) do
    current
    |> Enum.with_index()
    |> Enum.map(fn {round, idx} ->
      case Map.get(patches, Integer.to_string(idx)) do
        nil -> round
        patch when is_map(patch) -> apply_round_patch(round, patch)
      end
    end)
  end

  defp apply_round_patch(round, patch) do
    round
    |> maybe_put_round_type(Map.get(patch, "type"))
    |> maybe_put_round_opts(Map.get(patch, "opts_json"))
  end

  defp maybe_put_round_type(round, nil), do: round
  defp maybe_put_round_type(round, ""), do: round

  defp maybe_put_round_type(round, type) when is_binary(type) do
    if type in @round_types, do: Map.put(round, "type", type), else: round
  end

  # `opts_json` arrives as a textarea string. Empty / blank → empty map.
  # Bad JSON → keep prior opts so the editor doesn't lose work mid-typing;
  # validation happens at save time via DynamicRound.new/1.
  defp maybe_put_round_opts(round, nil), do: round
  defp maybe_put_round_opts(round, ""), do: Map.put(round, "opts", %{})

  defp maybe_put_round_opts(round, raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> Map.put(round, "opts", map)
      _ -> round
    end
  end

  # Member/chair `<select>` for model posts a combined `provider:model_id`
  # value as `model_ref`; numeric override fields arrive as strings under
  # `overrides[temperature]` / `overrides[max_tokens]`. Normalize both into
  # the flat member-map shape we persist.
  defp normalize_member_patch(%{} = patch) do
    {overrides, rest} = Map.pop(patch, "overrides", %{})

    rest
    |> normalize_model_ref()
    |> merge_overrides(overrides)
    |> normalize_optional_select("profile")
    |> normalize_optional_select("output_schema")
    |> normalize_tools_field()
    |> normalize_optional_select("sub_council_kind")
    |> normalize_optional_select("sub_council_ref")
    |> normalize_optional_select("input_mapper")
    |> normalize_inline_schema_field()
  end

  # Inline schema arrives as a textarea string. Pass through verbatim while
  # editing — parse / validate at save time so we don't lose mid-typing
  # work.
  defp normalize_inline_schema_field(patch) do
    case Map.get(patch, "output_schema_inline") do
      nil -> patch
      v when is_binary(v) -> Map.put(patch, "output_schema_inline", v)
      _ -> patch
    end
  end

  defp normalize_optional_select(patch, key) do
    case Map.get(patch, key) do
      nil -> patch
      "" -> Map.put(patch, key, nil)
      v when is_binary(v) -> Map.put(patch, key, v)
      _ -> patch
    end
  end

  defp normalize_tools_field(patch) do
    case Map.get(patch, "tools") do
      nil -> patch
      list when is_list(list) -> Map.put(patch, "tools", normalize_string_list(list))
      _ -> patch
    end
  end

  defp normalize_model_ref(%{} = patch) do
    case Map.pop(patch, "model_ref") do
      {nil, rest} ->
        rest

      {"", rest} ->
        Map.merge(rest, %{"provider" => nil, "model" => nil})

      {ref, rest} when is_binary(ref) ->
        case String.split(ref, ":", parts: 2) do
          [provider, model_id] ->
            Map.merge(rest, %{"provider" => provider, "model" => model_id})

          _ ->
            rest
        end
    end
  end

  defp merge_overrides(patch, %{} = overrides) do
    Enum.reduce(@override_numeric_keys, patch, fn key, acc ->
      case Map.get(overrides, key) do
        nil -> acc
        "" -> Map.put(acc, key, nil)
        raw when is_binary(raw) -> Map.put(acc, key, parse_number(raw, acc[key]))
        n when is_number(n) -> Map.put(acc, key, n)
        _ -> acc
      end
    end)
  end

  defp merge_overrides(patch, _), do: patch

  defp parse_number(str, prev) do
    case Float.parse(str) do
      {f, ""} ->
        if Float.floor(f) == f and not String.contains?(str, "."), do: trunc(f), else: f

      _ ->
        prev
    end
  end

  defp swap(list, i, j) when i < 0 or j < 0, do: list
  defp swap(list, i, j) when i >= length(list) or j >= length(list), do: list

  defp swap(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)

    list
    |> List.replace_at(i, b)
    |> List.replace_at(j, a)
  end

  defp new_member(idx) do
    %{
      "id" => "member_#{idx}",
      "role" => nil,
      "provider" => nil,
      "model" => nil,
      "system_prompt" => "You are a helpful council member.",
      "temperature" => nil,
      "max_tokens" => nil,
      "profile" => nil,
      "tools" => [],
      "output_schema" => nil,
      "output_schema_inline" => nil,
      "sub_council_kind" => "none",
      "sub_council_ref" => nil,
      "input_mapper" => nil
    }
  end

  # ── Spec hydration helpers ──────────────────────────────────────────
  #
  # Older specs persisted before this revision are missing `role`,
  # `temperature`, `max_tokens`, or use round-as-string. Backfill so the
  # form has a stable shape in both `:new` and `:edit` modes.

  defp normalize_member_list(members) when is_list(members),
    do: Enum.map(members, &normalize_member_map/1)

  defp normalize_member_list(_), do: []

  defp normalize_member_map(%{} = m) do
    {sub_kind, sub_ref} = decode_sub_council(m["sub_council"])

    %{
      "id" => m["id"] || "member",
      "role" => m["role"],
      "provider" => m["provider"],
      "model" => m["model"],
      "system_prompt" => m["system_prompt"] || "",
      "temperature" => m["temperature"],
      "max_tokens" => m["max_tokens"],
      "profile" => m["profile"],
      "tools" => normalize_string_list(Map.get(m, "tools", [])),
      "output_schema" => m["output_schema"],
      "output_schema_inline" => inline_schema_to_json(m["output_schema_inline"]),
      "sub_council_kind" => sub_kind,
      "sub_council_ref" => sub_ref,
      "input_mapper" => m["input_mapper"]
    }
  end

  defp decode_sub_council(nil), do: {"none", nil}
  defp decode_sub_council(name) when is_binary(name), do: {"registered", name}

  defp decode_sub_council(%{"module" => mod}) when is_binary(mod), do: {"module", mod}

  # Nested DynamicCouncil maps aren't editable here. Surface as a read-only
  # marker so the user knows it's there; saving will preserve the original
  # only if they re-enter the same module/name (otherwise it gets
  # overwritten). Treat as `none` for editing.
  defp decode_sub_council(_), do: {"none", nil}

  defp inline_schema_to_json(nil), do: nil
  defp inline_schema_to_json(map) when is_map(map), do: Jason.encode!(map)
  defp inline_schema_to_json(other) when is_binary(other), do: other
  defp inline_schema_to_json(_), do: nil

  defp normalize_string_list(list) when is_list(list) do
    list
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp normalize_string_list(_), do: []

  defp normalize_chair_map(%{} = m), do: normalize_member_map(m)
  defp normalize_chair_map(_), do: default_chair()

  defp normalize_round_list(rounds) when is_list(rounds),
    do: Enum.map(rounds, &normalize_round_entry/1)

  defp normalize_round_list(_), do: default_rounds()

  defp normalize_round_entry(name) when is_binary(name), do: %{"type" => name, "opts" => %{}}

  defp normalize_round_entry(%{"type" => _} = m),
    do: %{"type" => m["type"], "opts" => Map.get(m, "opts", %{})}

  defp normalize_round_entry(other), do: %{"type" => to_string(other), "opts" => %{}}

  # ── Diagram preview ─────────────────────────────────────────────────

  defp recompute_diagram(socket) do
    spec = %{
      "members" => Enum.map(socket.assigns.members, &diagram_member/1),
      "rounds" => Enum.map(socket.assigns.rounds, &diagram_round/1),
      "chair" => diagram_member(socket.assigns.chairman)
    }

    assign(socket, :diagram_spec, Jason.encode!(spec))
  end

  defp diagram_member(%{} = m) do
    %{
      "id" => m["id"] || "?",
      "provider" => m["provider"],
      "model" => m["model"],
      "system_prompt" => m["system_prompt"]
    }
  end

  defp diagram_member(_), do: nil

  defp diagram_round(%{"type" => name}) when is_binary(name) do
    %{"name" => name, "type" => infer_round_type(name)}
  end

  defp diagram_round(_), do: %{"name" => "round", "type" => "custom"}

  # Mirrors `ConcilioWeb.CouncilShowLive.infer_round_type/2` so the live
  # preview colors edges identically to the run / show diagrams.
  defp infer_round_type(name) when is_binary(name) do
    h = String.downcase(name)

    cond do
      Regex.match?(~r/peer[\s_-]*review/, h) -> "peer_review"
      Regex.match?(~r/revis|iterate|refine/, h) -> "revision"
      Regex.match?(~r/debate/, h) -> "debate"
      Regex.match?(~r/independent/, h) -> "independent"
      Regex.match?(~r/synth/, h) -> "synthesize"
      true -> "custom"
    end
  end

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} max_w="max-w-7xl">
      <div class="space-y-6">
        <div class="flex items-baseline justify-between">
          <h1 class="text-2xl font-semibold">{@page_title}</h1>
          <.link navigate={~p"/councils"} class="link link-hover text-sm">← Councils</.link>
        </div>

        <%= if @errors != [] do %>
          <div class="alert alert-error text-sm">
            <ul class="list-disc pl-5">
              <li :for={err <- @errors}>{err}</li>
            </ul>
          </div>
        <% end %>

        <%= if @prebuilt do %>
          <div class="alert alert-info text-sm">
            <.icon name="hero-sparkles" class="size-4" />
            <span>
              Scaffolded from <span class="font-semibold">{@prebuilt.name}</span>
              — rounds and chair are pre-filled. Fill in members, pick provider/model, then save.
              <span class="font-mono text-xs opacity-70">{@prebuilt.module}</span>
            </span>
          </div>
        <% end %>

        <div class="grid grid-cols-1 lg:grid-cols-5 gap-6">
          <div class="lg:col-span-3 space-y-6">
            <.form for={@form} phx-change="form_change" phx-submit="save" class="space-y-6">
              <div class="card bg-base-100 border border-base-300">
                <div class="card-body space-y-4">
                  <.input field={@form[:name]} type="text" label="Name" required />
                  <fieldset class="fieldset">
                    <legend class="fieldset-legend">Description</legend>
                    <textarea
                      name="builder[description]"
                      class="textarea w-full"
                      rows="2"
                      placeholder="Short summary shown on the council index card."
                    ><%= @form[:description].value %></textarea>
                  </fieldset>
                </div>
              </div>

              <div class="card bg-base-100 border border-base-300">
                <div class="card-body space-y-3">
                  <div class="flex items-baseline justify-between">
                    <h2 class="card-title text-base">Members</h2>
                    <button type="button" class="btn btn-ghost btn-xs" phx-click="add_member">
                      + Add member
                    </button>
                  </div>

                  <%= if @members == [] do %>
                    <p class="text-sm text-base-content/60">No members yet — add at least one.</p>
                  <% end %>

                  <%= for {member, idx} <- Enum.with_index(@members) do %>
                    <.member_row
                      index={idx}
                      member={member}
                      working_set={@working_set}
                      profiles={@registered_profiles}
                      tools={@registered_tools}
                      schemas={@registered_schemas}
                      sub_councils={@registered_sub_councils}
                      input_mappers={@registered_input_mappers}
                      static_templates={@static_templates}
                    />
                  <% end %>
                </div>
              </div>

              <div class="card bg-base-100 border border-base-300">
                <div class="card-body space-y-3">
                  <div class="flex items-baseline justify-between">
                    <h2 class="card-title text-base">Rounds</h2>
                    <button type="button" class="btn btn-ghost btn-xs" phx-click="add_round">
                      + Add round
                    </button>
                  </div>

                  <%= if @rounds == [] do %>
                    <p class="text-sm text-base-content/60">
                      No rounds yet — at least one is required.
                    </p>
                  <% end %>

                  <%= for {round, idx} <- Enum.with_index(@rounds) do %>
                    <.round_row
                      index={idx}
                      total={length(@rounds)}
                      round={round}
                      round_types={@round_types}
                    />
                  <% end %>
                </div>
              </div>

              <div class="card bg-base-100 border border-base-300">
                <div class="card-body space-y-3">
                  <h2 class="card-title text-base">Chairman</h2>
                  <.chair_row
                    chairman={@chairman}
                    working_set={@working_set}
                    profiles={@registered_profiles}
                    tools={@registered_tools}
                    schemas={@registered_schemas}
                    sub_councils={@registered_sub_councils}
                    input_mappers={@registered_input_mappers}
                    static_templates={@static_templates}
                  />
                </div>
              </div>

              <details class="card bg-base-100 border border-base-300">
                <summary class="card-body cursor-pointer">
                  <span class="card-title text-base">Advanced</span>
                  <span class="text-xs text-base-content/60">
                    Council-level defaults: default profile, router, shared tools.
                  </span>
                </summary>
                <div class="card-body pt-0 space-y-3">
                  <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                    <fieldset class="fieldset">
                      <legend class="fieldset-legend">Default profile</legend>
                      <select class="select w-full" name="council[default_profile]">
                        <option value="" selected={is_nil(@default_profile)}>
                          (none)
                        </option>
                        <option
                          :for={p <- @registered_profiles}
                          value={p}
                          selected={@default_profile == p}
                        >
                          {p}
                        </option>
                      </select>
                      <p class="text-xs text-base-content/60">
                        Members without their own profile inherit this.
                      </p>
                    </fieldset>

                    <fieldset class="fieldset">
                      <legend class="fieldset-legend">Router</legend>
                      <select class="select w-full" name="council[router]">
                        <option value="" selected={is_nil(@router)}>(none)</option>
                        <option
                          :for={r <- @registered_routers}
                          value={r}
                          selected={@router == r}
                        >
                          {r}
                        </option>
                      </select>
                      <%= if @registered_routers == [] do %>
                        <p class="text-xs text-base-content/60">
                          No routers registered.
                        </p>
                      <% end %>
                    </fieldset>
                  </div>

                  <fieldset class="fieldset">
                    <legend class="fieldset-legend">Council tools</legend>
                    <.tool_checkboxes
                      name_prefix="council"
                      selected={@council_tools}
                      tools={@registered_tools}
                    />
                  </fieldset>

                  <fieldset class="fieldset">
                    <legend class="fieldset-legend">Metadata (JSON)</legend>
                    <textarea
                      class="textarea w-full font-mono text-xs"
                      rows="3"
                      name="council[metadata_json]"
                      placeholder='{"version": "1.0"}'
                    ><%= @metadata_json %></textarea>
                    <p class="text-xs text-base-content/60">
                      Free-form map. Surfaces in CouncilEx events / UI position hints.
                    </p>
                  </fieldset>
                </div>
              </details>

              <div class="flex justify-end gap-2">
                <.link navigate={~p"/councils"} class="btn btn-ghost btn-sm">Cancel</.link>
                <button type="submit" class="btn btn-primary btn-sm">
                  {if @mode == :new, do: "Create", else: "Save new version"}
                </button>
              </div>
            </.form>
          </div>

          <div class="lg:col-span-2">
            <div class="card bg-base-100 border border-base-300 lg:sticky lg:top-4">
              <div class="card-body">
                <h2 class="card-title text-base">Live preview</h2>
                <p class="text-xs text-base-content/60">
                  Rounds trellis updates as you edit. Each row = one round; edges show what each member reads from the previous round. Read-only.
                </p>
                <div
                  id="builder-diagram"
                  phx-hook="CouncilDiagram"
                  phx-update="ignore"
                  data-spec={@diagram_spec}
                  class="w-full h-[600px] rounded border border-base-300 bg-base-100"
                >
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :index, :integer, required: true
  attr :member, :map, required: true
  attr :working_set, :list, required: true
  attr :profiles, :list, required: true
  attr :tools, :list, required: true
  attr :schemas, :list, required: true
  attr :sub_councils, :list, required: true
  attr :input_mappers, :list, required: true
  attr :static_templates, :list, required: true

  defp member_row(assigns) do
    ~H"""
    <div class="border border-base-300 rounded p-3 space-y-2">
      <div class="flex items-baseline justify-between">
        <span class="text-sm font-mono">#{@index + 1}</span>
        <button
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="remove_member"
          phx-value-index={@index}
        >
          Remove
        </button>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <fieldset class="fieldset">
          <legend class="fieldset-legend">Member id</legend>
          <input
            type="text"
            value={@member["id"]}
            class="input w-full"
            name={"members[#{@index}][id]"}
          />
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">Role</legend>
          <input
            type="text"
            value={@member["role"]}
            class="input w-full"
            name={"members[#{@index}][role]"}
            placeholder="e.g. Skeptic"
          />
        </fieldset>

        <fieldset class="fieldset md:col-span-2">
          <legend class="fieldset-legend">Model</legend>
          <select class="select w-full" name={"members[#{@index}][model_ref]"}>
            <option value="" disabled selected={is_nil(@member["model"])}>Pick a model…</option>
            <option
              :for={m <- @working_set}
              value={"#{m.provider}:#{m.model_id}"}
              selected={
                @member["provider"] == to_string(m.provider) and @member["model"] == m.model_id
              }
            >
              {m.provider}/{m.model_id}
            </option>
          </select>
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">Temperature</legend>
          <input
            type="number"
            step="0.1"
            min="0"
            max="2"
            value={@member["temperature"]}
            class="input w-full"
            name={"members[#{@index}][overrides][temperature]"}
            placeholder="profile default"
          />
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">Max tokens</legend>
          <input
            type="number"
            step="1"
            min="1"
            value={@member["max_tokens"]}
            class="input w-full"
            name={"members[#{@index}][overrides][max_tokens]"}
            placeholder="profile default"
          />
        </fieldset>
      </div>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">System prompt</legend>
        <textarea
          class="textarea w-full"
          rows="3"
          name={"members[#{@index}][system_prompt]"}
        ><%= @member["system_prompt"] %></textarea>
      </fieldset>

      <details class="border border-base-300/60 rounded">
        <summary class="px-3 py-2 cursor-pointer text-xs text-base-content/70">
          Advanced — tools, output schema, sub-council
        </summary>
        <div class="p-3 space-y-3">
          <fieldset class="fieldset">
            <legend class="fieldset-legend">Output schema</legend>
            <select class="select w-full" name={"members[#{@index}][output_schema]"}>
              <option value="" selected={is_nil(@member["output_schema"])}>(none)</option>
              <option
                :for={s <- @schemas}
                value={s}
                selected={@member["output_schema"] == s}
              >
                {s}
              </option>
            </select>
            <p class="text-xs text-base-content/60">
              Profile inherits from council default — set under <em>Advanced</em> below.
            </p>
          </fieldset>

          <fieldset class="fieldset">
            <legend class="fieldset-legend">Output schema (inline JSON)</legend>
            <textarea
              class="textarea w-full font-mono text-xs"
              rows="2"
              name={"members[#{@index}][output_schema_inline]"}
              placeholder='{"type": "object", "properties": {...}}'
            ><%= @member["output_schema_inline"] %></textarea>
            <p class="text-xs text-base-content/60">
              Mutually exclusive with the registered-schema select above.
            </p>
          </fieldset>

          <fieldset class="fieldset">
            <legend class="fieldset-legend">Tools</legend>
            <.tool_checkboxes
              name_prefix={"members[#{@index}]"}
              selected={@member["tools"] || []}
              tools={@tools}
            />
          </fieldset>

          <.sub_council_picker
            name_prefix={"members[#{@index}]"}
            kind={@member["sub_council_kind"] || "none"}
            ref={@member["sub_council_ref"]}
            input_mapper={@member["input_mapper"]}
            sub_councils={@sub_councils}
            input_mappers={@input_mappers}
            static_templates={@static_templates}
          />
        </div>
      </details>
    </div>
    """
  end

  attr :name_prefix, :string, required: true
  attr :kind, :string, required: true
  attr :ref, :string, default: nil
  attr :input_mapper, :string, default: nil
  attr :sub_councils, :list, required: true
  attr :input_mappers, :list, required: true
  attr :static_templates, :list, required: true

  defp sub_council_picker(assigns) do
    ~H"""
    <fieldset class="fieldset border border-base-300/60 rounded p-2">
      <legend class="fieldset-legend">Sub-council (advanced)</legend>
      <p class="text-xs text-base-content/60">
        Replace this member with a nested council run. Other member fields are ignored when set.
      </p>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-3 mt-2">
        <fieldset class="fieldset">
          <legend class="fieldset-legend">Source</legend>
          <select class="select w-full" name={"#{@name_prefix}[sub_council_kind]"}>
            <option value="none" selected={@kind == "none"}>None</option>
            <option value="registered" selected={@kind == "registered"}>Registered name</option>
            <option value="module" selected={@kind == "module"}>Static template</option>
          </select>
        </fieldset>

        <fieldset class="fieldset md:col-span-2">
          <legend class="fieldset-legend">Reference</legend>
          <%= cond do %>
            <% @kind == "registered" -> %>
              <select class="select w-full" name={"#{@name_prefix}[sub_council_ref]"}>
                <option value="" selected={is_nil(@ref)}>Pick…</option>
                <option :for={n <- @sub_councils} value={n} selected={@ref == n}>{n}</option>
              </select>
              <%= if @sub_councils == [] do %>
                <p class="text-xs text-base-content/60">
                  No sub-councils registered. Register via
                  <code>CouncilEx.Registry.register_sub_council/2</code>
                  or config.
                </p>
              <% end %>
            <% @kind == "module" -> %>
              <select class="select w-full" name={"#{@name_prefix}[sub_council_ref]"}>
                <option value="" selected={is_nil(@ref)}>Pick a static template…</option>
                <option
                  :for={t <- @static_templates}
                  value={t.module}
                  selected={@ref == t.module}
                >
                  {t.name}
                </option>
              </select>
            <% true -> %>
              <input
                type="hidden"
                name={"#{@name_prefix}[sub_council_ref]"}
                value=""
              />
              <p class="text-xs text-base-content/50 italic">Not a sub-council member.</p>
          <% end %>
        </fieldset>
      </div>

      <fieldset class="fieldset mt-2">
        <legend class="fieldset-legend">Input mapper</legend>
        <select class="select w-full" name={"#{@name_prefix}[input_mapper]"}>
          <option value="" selected={is_nil(@input_mapper)}>(identity)</option>
          <option
            :for={m <- @input_mappers}
            value={m}
            selected={@input_mapper == m}
          >
            {m}
          </option>
        </select>
        <p class="text-xs text-base-content/60">
          Optional registered 1-arity function that projects parent input before the inner run.
        </p>
      </fieldset>
    </fieldset>
    """
  end

  attr :name_prefix, :string, required: true
  attr :selected, :list, required: true
  attr :tools, :list, required: true

  defp tool_checkboxes(assigns) do
    ~H"""
    <%= if @tools == [] do %>
      <p class="text-xs text-base-content/60">No tools registered.</p>
    <% else %>
      <input type="hidden" name={"#{@name_prefix}[tools][]"} value="" />
      <div class="flex flex-wrap gap-3">
        <label :for={t <- @tools} class="label cursor-pointer gap-2">
          <input
            type="checkbox"
            class="checkbox checkbox-sm"
            name={"#{@name_prefix}[tools][]"}
            value={t}
            checked={t in @selected}
          />
          <span class="label-text text-xs font-mono">{t}</span>
        </label>
      </div>
    <% end %>
    """
  end

  attr :index, :integer, required: true
  attr :total, :integer, required: true
  attr :round, :map, required: true
  attr :round_types, :list, required: true

  defp round_row(assigns) do
    ~H"""
    <div class="border border-base-300 rounded p-3 space-y-2">
      <div class="flex items-baseline justify-between">
        <span class="text-sm font-mono">round #{@index + 1}</span>
        <div class="flex gap-1">
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="move_round_up"
            phx-value-index={@index}
            disabled={@index == 0}
          >
            ↑
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="move_round_down"
            phx-value-index={@index}
            disabled={@index >= @total - 1}
          >
            ↓
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="remove_round"
            phx-value-index={@index}
          >
            Remove
          </button>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <fieldset class="fieldset">
          <legend class="fieldset-legend">Type</legend>
          <select class="select w-full" name={"rounds[#{@index}][type]"}>
            <option :for={t <- @round_types} value={t} selected={@round["type"] == t}>
              {t}
            </option>
          </select>
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">Opts (JSON)</legend>
          <textarea
            class="textarea w-full font-mono text-xs"
            rows="2"
            name={"rounds[#{@index}][opts_json]"}
            placeholder='{"max_iterations": 3}'
          ><%= opts_to_json(@round["opts"]) %></textarea>
        </fieldset>
      </div>
    </div>
    """
  end

  defp opts_to_json(nil), do: ""
  defp opts_to_json(map) when map == %{}, do: ""
  defp opts_to_json(map) when is_map(map), do: Jason.encode!(map)
  defp opts_to_json(_), do: ""

  attr :chairman, :map, required: true
  attr :working_set, :list, required: true
  attr :profiles, :list, required: true
  attr :tools, :list, required: true
  attr :schemas, :list, required: true
  attr :sub_councils, :list, required: true
  attr :input_mappers, :list, required: true
  attr :static_templates, :list, required: true

  defp chair_row(assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
      <fieldset class="fieldset">
        <legend class="fieldset-legend">Chair id</legend>
        <input
          type="text"
          value={@chairman["id"]}
          class="input w-full"
          name="chairman[id]"
        />
      </fieldset>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">Role</legend>
        <input
          type="text"
          value={@chairman["role"]}
          class="input w-full"
          name="chairman[role]"
          placeholder="e.g. Pundit"
        />
      </fieldset>

      <fieldset class="fieldset md:col-span-2">
        <legend class="fieldset-legend">Model</legend>
        <select class="select w-full" name="chairman[model_ref]">
          <option value="" disabled selected={is_nil(@chairman["model"])}>Pick a model…</option>
          <option
            :for={m <- @working_set}
            value={"#{m.provider}:#{m.model_id}"}
            selected={
              @chairman["provider"] == to_string(m.provider) and @chairman["model"] == m.model_id
            }
          >
            {m.provider}/{m.model_id}
          </option>
        </select>
      </fieldset>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">Temperature</legend>
        <input
          type="number"
          step="0.1"
          min="0"
          max="2"
          value={@chairman["temperature"]}
          class="input w-full"
          name="chairman[overrides][temperature]"
          placeholder="profile default"
        />
      </fieldset>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">Max tokens</legend>
        <input
          type="number"
          step="1"
          min="1"
          value={@chairman["max_tokens"]}
          class="input w-full"
          name="chairman[overrides][max_tokens]"
          placeholder="profile default"
        />
      </fieldset>

      <fieldset class="fieldset md:col-span-2">
        <legend class="fieldset-legend">System prompt</legend>
        <textarea class="textarea w-full" rows="3" name="chairman[system_prompt]"><%= @chairman["system_prompt"] %></textarea>
      </fieldset>

      <details class="md:col-span-2 border border-base-300/60 rounded">
        <summary class="px-3 py-2 cursor-pointer text-xs text-base-content/70">
          Advanced — tools, output schema, sub-council
        </summary>
        <div class="p-3 space-y-3">
          <fieldset class="fieldset">
            <legend class="fieldset-legend">Output schema</legend>
            <select class="select w-full" name="chairman[output_schema]">
              <option value="" selected={is_nil(@chairman["output_schema"])}>(none)</option>
              <option
                :for={s <- @schemas}
                value={s}
                selected={@chairman["output_schema"] == s}
              >
                {s}
              </option>
            </select>
            <p class="text-xs text-base-content/60">
              Profile inherits from council default.
            </p>
          </fieldset>

          <fieldset class="fieldset">
            <legend class="fieldset-legend">Output schema (inline JSON)</legend>
            <textarea
              class="textarea w-full font-mono text-xs"
              rows="2"
              name="chairman[output_schema_inline]"
              placeholder='{"type": "object", "properties": {...}}'
            ><%= @chairman["output_schema_inline"] %></textarea>
            <p class="text-xs text-base-content/60">
              Mutually exclusive with the registered-schema select above.
            </p>
          </fieldset>

          <fieldset class="fieldset">
            <legend class="fieldset-legend">Tools</legend>
            <.tool_checkboxes
              name_prefix="chairman"
              selected={@chairman["tools"] || []}
              tools={@tools}
            />
          </fieldset>

          <.sub_council_picker
            name_prefix="chairman"
            kind={@chairman["sub_council_kind"] || "none"}
            ref={@chairman["sub_council_ref"]}
            input_mapper={@chairman["input_mapper"]}
            sub_councils={@sub_councils}
            input_mappers={@input_mappers}
            static_templates={@static_templates}
          />
        </div>
      </details>
    </div>
    """
  end
end
