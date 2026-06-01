defmodule Concilio.Serialization do
  @moduledoc """
  JSON-friendly serialization for `council_ex` event payloads and
  result structs. We never write `:erlang.term_to_binary` to a column;
  every persisted struct goes through an explicit `to_map/1` here and
  comes back through `from_map/1` when needed.

  Each `to_map/1` adds a `"__struct__"` tag so we can roundtrip; the
  outer `payload_version` column on the row tracks schema migrations
  for the JSON shape.
  """

  @doc """
  Convert any struct (or value) into a JSON-shaped map.
  Plain values (strings, numbers, atoms, nil, bools, lists, maps) pass
  through with atom-key normalization to strings (for maps).
  """
  @spec to_map(term()) :: term()
  def to_map(value), do: convert(value)

  @doc """
  Build a payload map from an arbitrary `council_ex` event tuple. The
  shape is:

      %{
        "type"  => "<event name as string>",
        "args"  => [<positional args after run_id>, ...]
      }

  The `run_id` is always the second tuple element and is stored on the
  parent `runs.run_id` column; we don't repeat it inside the payload.
  """
  @spec event_to_map(tuple()) :: %{String.t() => term()}
  def event_to_map(event) when is_tuple(event) do
    [type | rest] = Tuple.to_list(event)

    args =
      rest
      |> Enum.drop(1)
      |> Enum.map(&convert/1)

    %{"type" => Atom.to_string(type), "args" => args}
  end

  @doc """
  Returns the event type atom for a persisted payload.
  """
  @spec event_type(map()) :: atom()
  def event_type(%{"type" => type}) when is_binary(type), do: String.to_existing_atom(type)

  # ── private ─────────────────────────────────────────────────────────

  defp convert(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp convert(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  defp convert(%mod{} = struct) do
    base = struct |> Map.from_struct() |> drop_meta() |> convert()

    Map.put(base, "__struct__", inspect(mod))
  end

  defp convert(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_key(k), convert(v)} end)
  end

  defp convert(list) when is_list(list), do: Enum.map(list, &convert/1)
  defp convert(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.map(&convert/1)

  defp convert(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  # Function captures (e.g. `&Mod.fun/2`) appear in static-template specs that
  # carry round opts like `until:` callbacks. Persist a stable printable form;
  # static templates rebuild from `source_module` at run time, so the JSON copy
  # is informational only.
  defp convert(value) when is_function(value), do: inspect(value)

  defp convert(value) when is_pid(value) or is_reference(value) or is_port(value),
    do: inspect(value)

  defp convert(value), do: value

  defp drop_meta(map), do: Map.drop(map, [:__meta__])

  defp to_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_key(k) when is_binary(k), do: k
end
