defmodule Concilio.Councils.Roster do
  @moduledoc """
  Normalizes a `council_template_versions.spec_json` into a uniform roster
  shape (members + chair) with role, system_prompt, provider, model, and
  module fields filled in.

  Two spec shapes flow through here:

    * dynamic — built in `CouncilBuilderLive`, members are plain string-keyed
      maps already containing every field.
    * static  — `CouncilEx.Spec` serialized via `Concilio.Serialization`;
      members arrive as `[id, module_str, opts]` lists, with `role` and
      `system_prompt` only on the compiled module. We introspect the module
      to fill those in.
  """

  @type member_card :: %{
          id: String.t(),
          role: String.t() | nil,
          system_prompt: String.t() | nil,
          provider: String.t() | nil,
          model: String.t() | nil,
          module: String.t() | nil,
          kind: :member | :chair
        }

  @type t :: %{members: [member_card()], chair: member_card() | nil}

  @spec from_run(map()) :: t()
  def from_run(%{template_version: %{spec_json: spec}}) when is_map(spec), do: from_spec(spec)
  def from_run(_), do: %{members: [], chair: nil}

  @spec from_spec(map()) :: t()
  def from_spec(spec) when is_map(spec) do
    members =
      spec
      |> Map.get("members", [])
      |> Enum.map(&normalize(&1, :member))

    chair =
      case spec["chairman"] || spec["chair"] do
        nil -> nil
        c -> normalize(c, :chair)
      end

    %{members: members, chair: chair}
  end

  def from_spec(_), do: %{members: [], chair: nil}

  defp normalize(%{} = m, kind) do
    module_str = m["module"]

    base = %{
      id: to_string(m["id"] || "?"),
      role: m["role"],
      system_prompt: m["system_prompt"],
      provider: m["provider"],
      model: m["model"],
      module: short_module(module_str),
      kind: kind
    }

    fill_from_module(base, module_str)
  end

  defp normalize([id, module_str, opts], kind) do
    opts_map = opts_to_map(opts)

    base = %{
      id: to_string(id),
      role: opts_map["role"],
      system_prompt: opts_map["system_prompt"],
      provider: opts_map["provider"],
      model: opts_map["model"],
      module: short_module(module_str),
      kind: kind
    }

    fill_from_module(base, module_str)
  end

  defp normalize(other, kind) do
    %{
      id: inspect(other),
      role: nil,
      system_prompt: nil,
      provider: nil,
      model: nil,
      module: nil,
      kind: kind
    }
  end

  defp fill_from_module(card, module_str) when is_binary(module_str) do
    case resolve_module(module_str) do
      nil ->
        card

      mod ->
        card
        |> maybe_put(:role, fn -> safe_call(mod, :role, []) end)
        |> maybe_put(:system_prompt, fn -> safe_call(mod, :system_prompt, [%{}]) end)
    end
  end

  defp fill_from_module(card, _), do: card

  defp maybe_put(card, key, fun) do
    if Map.get(card, key) do
      card
    else
      Map.put(card, key, fun.())
    end
  end

  defp resolve_module("Elixir." <> _ = str) do
    mod = String.to_atom(str)
    if Code.ensure_loaded?(mod), do: mod
  rescue
    _ -> nil
  end

  defp resolve_module(str) when is_binary(str) do
    resolve_module("Elixir." <> str)
  end

  defp resolve_module(_), do: nil

  defp safe_call(mod, fun, args) do
    if function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    end
  rescue
    _ -> nil
  end

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

  defp short_module(nil), do: nil
  defp short_module("Elixir." <> rest), do: rest
  defp short_module(str) when is_binary(str), do: str
  defp short_module(_), do: nil
end
