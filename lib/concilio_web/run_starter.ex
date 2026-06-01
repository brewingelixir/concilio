defmodule ConcilioWeb.RunStarter do
  @moduledoc """
  Glue between the LV / controller layer and the council_ex runner.

  Resolves the council (static module or dynamic spec), pre-validates,
  then spawns a `Concilio.RunRecorder` GenServer under
  `Concilio.RunRecorder.Supervisor`. The recorder's own `init/1` is
  what calls `Concilio.CouncilExRunner.start_supervised_run/3` with
  `subscribe: true`, so the PubSub subscription is in place before
  the `RunServer` broadcasts `:run_started` (this fixes the
  documented race in `council_ex/docs/RUNNING_IN_PHOENIX.md` §3).

  The recorder also passes `relay_topics: ["concilio:runs"]`, so every
  council-run event is fanned out to the global `"concilio:runs"`
  topic for any future global activity feed.

  Returns `{:ok, %Concilio.Runs.Run{}}` on success.
  """

  alias Concilio.Councils.Template
  alias Concilio.RunRecorder
  alias Concilio.Runs.Run

  @type start_error ::
          {:missing_requirements, [term()]}
          | {:invalid_council, [term()]}
          | {:start_run_failed, term()}
          | {:dynamic_council_build_failed, String.t()}
          | term()

  @doc """
  Starts a run for a static or dynamic template. Returns the persisted
  Run row (the recorder inserted it before returning).
  """
  @spec start(Template.t(), term(), keyword()) :: {:ok, Run.t()} | {:error, start_error()}
  def start(template, input, opts \\ [])

  def start(%Template{kind: :static, source_module: source} = template, input, opts) do
    normalized = normalize_input(input)
    opts = apply_settings_defaults(opts)

    with :ok <- precheck(template),
         {:ok, module} <- resolve_module(source),
         version <- ensure_current_version!(template),
         :ok <- runner_module().validate(module) do
      spawn_recorder(module, normalized, template, version, opts)
    end
  end

  def start(%Template{kind: :dynamic} = template, input, opts) do
    normalized = normalize_input(input)
    opts = apply_settings_defaults(opts)
    version = ensure_current_version!(template)

    with :ok <- precheck(template),
         {:ok, council} <- build_dynamic_council(template, version),
         :ok <- runner_module().validate(council) do
      spawn_recorder(council, normalized, template, version, opts)
    end
  end

  # Snapshot user defaults into the run opts. Caller-supplied opts always
  # win, so callers can override per-run. Skipped silently if the Settings
  # GenServer is not running (test envs that opt out of bootstrappers).
  #
  # Per kickoff hard rule: in-flight runs use the values they captured at
  # start. The merge happens here, before `spawn_recorder/5`, so the
  # frozen opts ride into RunRecorder → CouncilExRunner.start_supervised_run.
  defp apply_settings_defaults(opts) do
    case Process.whereis(Concilio.Settings) do
      nil ->
        opts

      _pid ->
        d = Concilio.Settings.get_defaults()

        defaults_opts =
          [
            failure_mode: d.failure_mode,
            member_timeout_ms: d.member_timeout_ms
          ]

        Keyword.merge(defaults_opts, opts)
    end
  end

  defp spawn_recorder(council, input, template, version, opts) do
    args = %{
      council: council,
      input: input,
      template: template,
      version: version,
      parent_run_id: Keyword.get(opts, :parent_run_id),
      responder_kind: Keyword.get(opts, :responder_kind, :council),
      run_opts: Keyword.drop(opts, [:parent_run_id, :responder_kind, :rerun_of_run_id])
    }

    case DynamicSupervisor.start_child(Concilio.RunRecorder.Supervisor, {RunRecorder, args}) do
      {:ok, pid} ->
        {:ok, RunRecorder.get_run(pid)}

      {:error, {:start_run_failed, _reason} = err} ->
        {:error, err}

      {:error, {:invalid_council, _errs} = err} ->
        {:error, err}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Reject before talking to CouncilEx if any required provider/model is not
  # configured. Returns the same shape the index UI uses, so consumers can
  # render a list.
  defp precheck(template) do
    case template
         |> Concilio.Councils.spec_requirements()
         |> Concilio.Providers.missing_requirements() do
      [] -> :ok
      missing -> {:error, {:missing_requirements, missing}}
    end
  end

  # Hydrate a `%CouncilEx.DynamicCouncil{}` from the persisted spec_json. Maps
  # the builder's flat `provider` / `model` member fields into
  # `profile_overrides`, drops empty placeholder keys, and renames
  # `"chairman"` (builder convention) to `"chair"` (CouncilEx convention).
  @doc false
  def build_dynamic_council(template, version) do
    spec = version.spec_json || %{}

    members =
      spec
      |> Map.get("members", [])
      |> Enum.map(&dynamic_member_attrs/1)

    chair =
      case spec["chairman"] || spec["chair"] do
        nil -> nil
        m -> dynamic_member_attrs(m)
      end

    rounds = Map.get(spec, "rounds", [])

    council_map =
      %{
        "id" => template.id,
        "name" => template.name,
        "members" => members,
        "rounds" => rounds,
        "chair" => chair,
        "default_profile" => spec["default_profile"],
        "router" => spec["router"],
        "tools" => normalize_tool_list(spec["tools"]),
        "metadata" => normalize_metadata(spec["metadata"])
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == [] or v == %{} end)
      |> Map.new()

    {:ok, CouncilEx.DynamicCouncil.from_map(council_map)}
  rescue
    e in [ArgumentError, KeyError] ->
      {:error, {:dynamic_council_build_failed, Exception.message(e)}}
  end

  defp dynamic_member_attrs(%{} = m) do
    model = m["model"]
    # Legacy specs were saved with provider=nil (the old builder only captured
    # model). Backfill by looking up the model in the working set; if a single
    # provider has it, use that. Newer specs include provider directly.
    provider = m["provider"] || infer_provider_for_model(model)

    overrides =
      %{}
      |> maybe_put_provider(provider)
      |> maybe_put_override("model", model)
      |> maybe_put_numeric_override("temperature", m["temperature"])
      |> maybe_put_numeric_override("max_tokens", m["max_tokens"])

    base =
      %{}
      |> Map.put("id", m["id"] || "member")
      |> Map.put("system_prompt", m["system_prompt"] || "")
      |> maybe_put_string("role", m["role"])
      |> maybe_put_string("profile", m["profile"])
      |> maybe_put_string("output_schema", m["output_schema"])
      |> maybe_put_string("input_mapper", m["input_mapper"])
      |> maybe_put_tool_list("tools", m["tools"])
      |> maybe_put_inline_schema("output_schema_inline", m["output_schema_inline"])
      |> maybe_put_sub_council("sub_council", m["sub_council"])

    if map_size(overrides) > 0,
      do: Map.put(base, "profile_overrides", overrides),
      else: base
  end

  defp maybe_put_inline_schema(map, _k, nil), do: map
  defp maybe_put_inline_schema(map, _k, m) when m == %{}, do: map
  defp maybe_put_inline_schema(map, k, m) when is_map(m), do: Map.put(map, k, m)
  defp maybe_put_inline_schema(map, _k, _), do: map

  defp maybe_put_sub_council(map, _k, nil), do: map
  defp maybe_put_sub_council(map, _k, ""), do: map

  defp maybe_put_sub_council(map, k, ref) when is_binary(ref), do: Map.put(map, k, ref)

  defp maybe_put_sub_council(map, k, %{"module" => mod} = ref)
       when is_binary(mod) and mod != "",
       do: Map.put(map, k, ref)

  defp maybe_put_sub_council(map, k, %{} = ref) when ref != %{}, do: Map.put(map, k, ref)
  defp maybe_put_sub_council(map, _k, _), do: map

  defp maybe_put_tool_list(map, _k, nil), do: map
  defp maybe_put_tool_list(map, _k, []), do: map

  defp maybe_put_tool_list(map, k, list) when is_list(list) do
    case normalize_tool_list(list) do
      [] -> map
      cleaned -> Map.put(map, k, cleaned)
    end
  end

  defp maybe_put_tool_list(map, _k, _), do: map

  defp normalize_tool_list(nil), do: []

  defp normalize_tool_list(list) when is_list(list) do
    list
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp normalize_tool_list(_), do: []

  defp normalize_metadata(nil), do: %{}
  defp normalize_metadata(m) when is_map(m), do: m
  defp normalize_metadata(_), do: %{}

  defp maybe_put_numeric_override(map, _k, nil), do: map
  defp maybe_put_numeric_override(map, _k, ""), do: map
  defp maybe_put_numeric_override(map, k, v) when is_number(v), do: Map.put(map, k, v)

  defp maybe_put_numeric_override(map, k, v) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} ->
        # max_tokens is integer; temperature is float. Coerce by key.
        if k == "max_tokens" do
          Map.put(map, k, trunc(f))
        else
          Map.put(map, k, f)
        end

      _ ->
        map
    end
  end

  defp maybe_put_numeric_override(map, _k, _), do: map

  defp maybe_put_string(map, _k, nil), do: map
  defp maybe_put_string(map, _k, ""), do: map
  defp maybe_put_string(map, k, v) when is_binary(v), do: Map.put(map, k, v)
  defp maybe_put_string(map, _k, _), do: map

  defp infer_provider_for_model(nil), do: nil
  defp infer_provider_for_model(""), do: nil

  defp infer_provider_for_model(model_id) when is_binary(model_id) do
    import Ecto.Query, only: [from: 2]

    Concilio.Repo.all(
      from m in Concilio.Providers.Model,
        where: m.model_id == ^model_id and m.in_working_set == true,
        where: is_nil(m.deprecated_at),
        select: m.provider
    )
    |> case do
      [single] -> single
      _ -> nil
    end
  end

  defp maybe_put_override(map, _k, nil), do: map
  defp maybe_put_override(map, _k, ""), do: map
  defp maybe_put_override(map, k, v), do: Map.put(map, k, v)

  # CouncilEx providers are atom-keyed (`:openai`, `:anthropic`, …). Convert
  # the stored string back to the matching existing atom; reject the override
  # if the atom isn't loaded so we surface a clear error rather than feeding
  # garbage into the runner.
  defp maybe_put_provider(map, nil), do: map
  defp maybe_put_provider(map, ""), do: map

  defp maybe_put_provider(map, p) when is_binary(p) do
    Map.put(map, "provider", String.to_existing_atom(p))
  rescue
    ArgumentError -> map
  end

  defp maybe_put_provider(map, p) when is_atom(p), do: Map.put(map, "provider", p)

  defp resolve_module(nil), do: {:error, :no_source_module}

  defp resolve_module(source) when is_binary(source) do
    case Code.ensure_loaded(String.to_existing_atom(source)) do
      {:module, mod} -> {:ok, mod}
      _ -> {:error, {:module_not_loaded, source}}
    end
  rescue
    ArgumentError -> {:error, {:unknown_module, source}}
  end

  defp ensure_current_version!(%Template{
         current_version: %Concilio.Councils.TemplateVersion{} = v
       }),
       do: v

  defp ensure_current_version!(%Template{current_version: nil}) do
    raise "template has no current version; was Concilio.Councils.sync_static_templates! run?"
  end

  defp ensure_current_version!(%Template{}) do
    raise "template's :current_version association is not loaded; preload it before calling RunStarter.start/3"
  end

  defp normalize_input(input) when is_map(input), do: input
  defp normalize_input(input) when is_binary(input), do: %{question: input}
  defp normalize_input(input), do: %{input: input}

  # Resolved at call time so tests can stub via Application.put_env/3.
  defp runner_module do
    Application.get_env(:concilio, :council_runner_module, Concilio.CouncilExRunner)
  end
end
