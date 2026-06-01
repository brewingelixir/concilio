defmodule Concilio.Councils do
  @moduledoc """
  Council templates: static (Elixir module) + dynamic (DB row + immutable
  versions). The two share the `council_templates` + `council_template_versions`
  tables and surface identically to the run pipeline.
  """

  import Ecto.Query, warn: false

  alias Concilio.Councils.{Template, TemplateVersion}
  alias Concilio.Repo
  alias Concilio.Serialization

  @doc """
  All non-archived templates ordered by name.
  """
  @spec list_templates(keyword()) :: [Template.t()]
  def list_templates(opts \\ []) do
    kind = Keyword.get(opts, :kind)

    query =
      from t in Template,
        where: is_nil(t.archived_at),
        order_by: [asc: t.name],
        preload: [:current_version]

    query = if kind, do: from(t in query, where: t.kind == ^kind), else: query
    Repo.all(query)
  end

  @doc """
  Fetch by slug. Raises if missing.
  """
  @spec get_by_slug!(String.t()) :: Template.t()
  def get_by_slug!(slug) do
    Template
    |> Repo.get_by!(slug: slug)
    |> Repo.preload(:current_version)
  end

  @doc """
  Fetch by id. Raises if missing.
  """
  @spec get!(Ecto.UUID.t()) :: Template.t()
  def get!(id) do
    Template
    |> Repo.get!(id)
    |> Repo.preload(:current_version)
  end

  @doc """
  Discover bundled static council modules under `Concilio.Councils.*`
  (modules implementing `__council__/0`) and upsert each one as a
  `Template` row with a single `TemplateVersion`. Idempotent.
  """
  @spec sync_static_templates!() :: [Template.t()]
  def sync_static_templates! do
    Enum.map(discover_static_modules(), &upsert_static_template!/1)
  end

  @doc """
  Walks the loaded application's modules looking for `Concilio.Councils.*`
  namespaces that export a `__council__/0` function (the marker `use
  CouncilEx` injects).
  """
  @spec discover_static_modules() :: [module()]
  def discover_static_modules do
    {:ok, modules} = :application.get_key(:concilio, :modules)

    Enum.filter(modules, fn module ->
      match?({:module, _}, Code.ensure_loaded(module)) and
        function_exported?(module, :__council__, 0) and
        under_councils_namespace?(module)
    end)
  end

  defp under_councils_namespace?(module) do
    module
    |> Module.split()
    |> case do
      ["Concilio", "Councils" | _] -> true
      _ -> false
    end
  end

  @doc false
  # Test seam: same as the private upsert path, exposed so tests can
  # inject a fake static module without putting it under
  # `Concilio.Councils.*`.
  def __sync_one_for_test__(module), do: upsert_static_template!(module)

  defp upsert_static_template!(module) do
    spec_map = Serialization.to_map(module.__council__())
    name = humanize(module)
    slug = slugify(module)
    source = Atom.to_string(module)
    description = description_for(module)
    samples = samples_for(module)

    Repo.transaction(fn ->
      template =
        case Repo.get_by(Template, slug: slug) do
          nil ->
            %Template{}
            |> Template.changeset(%{
              kind: :static,
              name: name,
              slug: slug,
              description: description,
              source_module: source,
              samples: samples
            })
            |> Repo.insert!()

          existing ->
            existing
            |> Template.changeset(%{
              name: name,
              description: description,
              source_module: source,
              samples: samples
            })
            |> Repo.update!()
        end

      version = upsert_static_version!(template, spec_map)

      template
      |> Template.changeset(%{current_version_id: version.id})
      |> Repo.update!()
    end)
    |> case do
      {:ok, template} -> Repo.preload(template, :current_version)
      {:error, reason} -> raise "failed to sync #{inspect(module)}: #{inspect(reason)}"
    end
  end

  # When a static module's spec drifts (someone edited the source) we
  # insert a NEW version row rather than mutating the existing one —
  # historical runs stay pinned to whatever they ran under, and
  # current_version_id flips to the latest. Idempotent: same spec
  # returns the same row.
  defp upsert_static_version!(template, spec_map) do
    latest =
      Repo.one(
        from v in TemplateVersion,
          where: v.template_id == ^template.id,
          order_by: [desc: v.version],
          limit: 1
      )

    cond do
      is_nil(latest) ->
        %TemplateVersion{}
        |> TemplateVersion.changeset(%{
          template_id: template.id,
          version: 1,
          spec_json: spec_map
        })
        |> Repo.insert!()

      latest.spec_json == spec_map ->
        latest

      true ->
        %TemplateVersion{}
        |> TemplateVersion.changeset(%{
          template_id: template.id,
          version: latest.version + 1,
          spec_json: spec_map
        })
        |> Repo.insert!()
    end
  end

  # ── Dynamic templates ───────────────────────────────────────────────

  @doc """
  Create a new dynamic template + version 1 in one transaction.
  `attrs` shape: %{name, slug, spec, cloned_from_template_id?,
  cloned_from_version_id?}.
  """
  @spec create_dynamic_template(map()) ::
          {:ok, Template.t()} | {:error, Ecto.Changeset.t() | term()}
  def create_dynamic_template(attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, template} <- insert_template(attrs),
           {:ok, version} <- insert_v1(template, attrs),
           {:ok, t} <- point_at_version(template, version) do
        Repo.preload(t, :current_version)
      else
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  defp insert_template(attrs) do
    attrs
    |> Map.take([:name, :slug, :description, :cloned_from_template_id, :cloned_from_version_id])
    |> Map.put(:kind, :dynamic)
    |> ensure_slug()
    |> then(&Template.changeset(%Template{}, &1))
    |> Repo.insert()
  end

  defp ensure_slug(%{slug: slug} = attrs) when is_binary(slug) and slug != "", do: attrs

  defp ensure_slug(attrs) do
    name = Map.get(attrs, :name) || ""
    Map.put(attrs, :slug, unique_slug_from_name(name))
  end

  @doc false
  @spec unique_slug_from_name(String.t()) :: String.t()
  def unique_slug_from_name(name) do
    base = slugify_name(name)
    base = if base == "", do: "council", else: base

    case Repo.get_by(Template, slug: base) do
      nil -> base
      _ -> "#{base}-#{:erlang.unique_integer([:positive])}"
    end
  end

  defp slugify_name(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
  end

  defp insert_v1(template, attrs) do
    %TemplateVersion{}
    |> TemplateVersion.changeset(%{
      template_id: template.id,
      version: 1,
      spec_json: Map.get(attrs, :spec, %{})
    })
    |> Repo.insert()
  end

  defp point_at_version(template, version) do
    template
    |> Template.changeset(%{current_version_id: version.id})
    |> Repo.update()
  end

  @doc """
  Persist a new immutable version on an existing dynamic template and
  flip `current_version_id` to point at it. Old runs stay pinned to
  the version they ran under.
  """
  @spec save_new_version(Template.t(), map()) ::
          {:ok, Template.t()} | {:error, Ecto.Changeset.t()}
  def save_new_version(%Template{kind: :dynamic} = template, spec) when is_map(spec) do
    Repo.transaction(fn ->
      latest =
        Repo.one(
          from(v in TemplateVersion,
            where: v.template_id == ^template.id,
            order_by: [desc: v.version],
            limit: 1
          )
        )

      next_version = (latest && latest.version + 1) || 1

      {:ok, version} =
        %TemplateVersion{}
        |> TemplateVersion.changeset(%{
          template_id: template.id,
          version: next_version,
          spec_json: spec
        })
        |> Repo.insert()

      {:ok, t} =
        template
        |> Template.changeset(%{current_version_id: version.id})
        |> Repo.update()

      Repo.preload(t, :current_version)
    end)
  end

  @doc """
  Fork any template into a new dynamic template seeded with the given
  template's current spec.
  """
  @spec clone_to_dynamic(Template.t(), map()) ::
          {:ok, Template.t()} | {:error, term()}
  def clone_to_dynamic(%Template{} = src, overrides \\ %{}) do
    src = Repo.preload(src, :current_version)
    raw_spec = (src.current_version && src.current_version.spec_json) || %{}
    spec = static_to_dynamic_spec(raw_spec)

    base_name = Map.get(overrides, :name, "#{src.name} (clone)")

    base_slug =
      Map.get(overrides, :slug, "#{src.slug}-clone-#{:erlang.unique_integer([:positive])}")

    create_dynamic_template(%{
      name: base_name,
      slug: base_slug,
      spec: spec,
      cloned_from_template_id: src.id,
      cloned_from_version_id: src.current_version_id
    })
  end

  @doc """
  Convert a serialized static `CouncilEx.Spec` (members/chair as
  `[id, module_str, opts]` lists, rounds as `[module_str, opts]`) into the
  dynamic-builder shape (string-keyed maps, rounds as
  `%{"type" => name, "opts" => map}`). Idempotent: already-dynamic specs pass
  through with member/chair/round values unchanged for their declared keys.

  Used at `clone_to_dynamic/2` time and as a defensive mount-time hydrator
  in `CouncilBuilderLive` so previously cloned (broken-shape) rows still
  edit cleanly.
  """
  @spec static_to_dynamic_spec(map()) :: map()
  def static_to_dynamic_spec(spec) when is_map(spec) do
    spec
    |> maybe_convert_list("members", &convert_member/1)
    |> maybe_convert_chair()
    |> maybe_convert_list("rounds", &convert_round/1)
  end

  def static_to_dynamic_spec(other), do: other

  defp maybe_convert_list(spec, key, fun) do
    case Map.fetch(spec, key) do
      {:ok, list} when is_list(list) -> Map.put(spec, key, Enum.map(list, fun))
      _ -> spec
    end
  end

  defp maybe_convert_chair(spec) do
    cond do
      Map.has_key?(spec, "chairman") -> Map.update!(spec, "chairman", &convert_member/1)
      Map.has_key?(spec, "chair") -> Map.update!(spec, "chair", &convert_member/1)
      true -> spec
    end
  end

  defp convert_member(%{} = m), do: m

  defp convert_member([id, _module_str, opts]) do
    o = opts_to_map(opts)

    %{
      "id" => to_string(id),
      "role" => o["role"],
      "provider" => o["provider"],
      "model" => o["model"],
      "system_prompt" => o["system_prompt"] || "",
      "temperature" => o["temperature"],
      "max_tokens" => o["max_tokens"],
      "profile" => o["profile"],
      "tools" => o["tools"] || []
    }
  end

  defp convert_member(other), do: %{"id" => inspect(other)}

  defp convert_round(name) when is_binary(name), do: %{"type" => name, "opts" => %{}}

  defp convert_round(%{"type" => _} = m), do: m

  defp convert_round([module_str, opts]) when is_binary(module_str) do
    %{"type" => round_type_from_module(module_str), "opts" => opts_to_map(opts)}
  end

  defp convert_round(other), do: %{"type" => to_string(other), "opts" => %{}}

  defp round_type_from_module(module_str) do
    module_str
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end

  @doc """
  Extract `{provider_atom, model_id}` pairs from a template's current_version
  spec_json. Handles both dynamic (string-keyed maps) and static (CouncilEx.Spec
  serialized as `[id, module, opts]` lists) shapes.
  """
  @spec spec_requirements(Template.t()) :: [{atom(), String.t()}]
  def spec_requirements(%Template{current_version: %{spec_json: spec}}) when is_map(spec) do
    members = Map.get(spec, "members", [])
    chair = spec["chairman"] || spec["chair"]

    [chair | members]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&extract_requirement/1)
    |> Enum.uniq()
  end

  def spec_requirements(_), do: []

  @doc """
  Distinct model_ids referenced by any non-archived council template's
  current version for `provider`. Used by Settings to pre-select models
  needed by the user's councils when they enable a provider.
  """
  @spec required_model_ids_for_provider(atom()) :: [String.t()]
  def required_model_ids_for_provider(provider) when is_atom(provider) do
    list_templates()
    |> Enum.flat_map(&spec_requirements/1)
    |> Enum.filter(fn {p, _} -> p == provider end)
    |> Enum.map(fn {_, m} -> m end)
    |> Enum.uniq()
  end

  defp extract_requirement(%{"provider" => p, "model" => m}) when is_binary(p) and is_binary(m),
    do: provider_pair(p, m)

  defp extract_requirement([_id, _module, opts]) do
    opts_map = opts_to_map(opts)
    p = opts_map["provider"]
    m = opts_map["model"]
    if is_binary(p) and is_binary(m), do: provider_pair(p, m), else: []
  end

  defp extract_requirement(_), do: []

  defp opts_to_map(opts) when is_map(opts), do: opts

  defp opts_to_map(opts) when is_list(opts) do
    Enum.reduce(opts, %{}, fn
      [k, v], acc when is_binary(k) -> Map.put(acc, k, v)
      {k, v}, acc when is_binary(k) -> Map.put(acc, k, v)
      {k, v}, acc when is_atom(k) -> Map.put(acc, Atom.to_string(k), v)
      _, acc -> acc
    end)
  end

  defp opts_to_map(_), do: %{}

  defp provider_pair(p, m) do
    [{String.to_existing_atom(p), m}]
  rescue
    ArgumentError -> []
  end

  defp humanize(module) do
    module
    |> Module.split()
    |> List.last()
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
  end

  defp slugify(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.replace("_", "-")
  end

  # Resolve a one-line human-friendly description for a static module.
  # Preference order:
  #   1. `__description__/0` callback (explicit, opt-in)
  #   2. First non-empty paragraph of the module's `@moduledoc`
  #   3. nil
  defp description_for(module) do
    if function_exported?(module, :__description__, 0) do
      case module.__description__() do
        d when is_binary(d) -> d
        _ -> nil
      end
    else
      description_from_moduledoc(module)
    end
  end

  defp description_from_moduledoc(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} when is_binary(moduledoc) ->
        moduledoc
        |> String.split("\n\n", parts: 2)
        |> List.first()
        |> String.trim()
        |> case do
          "" -> nil
          s -> s
        end

      _ ->
        nil
    end
  end

  # Samples for a static module. Each entry: %{"title" => string, "input" =>
  # string, "context" => string?}. Modules opt in via `samples/0`. Stored on
  # the template row as JSON; consumed by the Run-now modal to prefill input.
  defp samples_for(module) do
    if function_exported?(module, :samples, 0) do
      module.samples()
      |> List.wrap()
      |> Enum.map(&normalize_sample/1)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp normalize_sample(%{} = s) do
    title = s |> sample_field(:title) |> trim_or_nil()
    input = s |> sample_field(:input) |> trim_or_nil()
    context = s |> sample_field(:context) |> trim_or_nil()

    if is_nil(input) do
      nil
    else
      base = %{"title" => title || "Example", "input" => input}
      if context, do: Map.put(base, "context", context), else: base
    end
  end

  defp normalize_sample(_), do: nil

  defp sample_field(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp trim_or_nil(nil), do: nil

  defp trim_or_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      s -> s
    end
  end

  defp trim_or_nil(_), do: nil
end
