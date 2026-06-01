defmodule ConcilioWeb.Components.JsonTree do
  @moduledoc """
  Recursive HEEx component that renders an Elixir term (already JSON-shaped:
  maps with string keys, lists, primitives) as a collapsible, syntax-coloured
  tree using native `<details>` / `<summary>`. No JS dependency; works with
  LiveView updates by virtue of being a pure server-rendered component.

  Type colors (DaisyUI semantic tokens, theme-aware):

      string  → text-success
      number  → text-warning
      boolean → text-secondary
      null    → text-error
      key     → text-info
  """

  use Phoenix.Component

  attr :data, :any, required: true
  attr :name, :string, default: nil

  def json_tree(%{data: d} = assigns) when is_map(d) do
    pairs = d |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    assigns = assign(assigns, :pairs, pairs)

    ~H"""
    <details open class="ml-2">
      <summary class="cursor-pointer hover:bg-base-200 rounded px-1">
        <%= if @name do %>
          <span class="text-info">"{@name}"</span><span class="text-base-content/60">: </span>
        <% end %>
        <span class="text-base-content/60">{map_summary(@pairs)}</span>
      </summary>
      <div class="ml-3 border-l border-base-300 pl-2">
        <.json_tree :for={{k, v} <- @pairs} data={v} name={to_string(k)} />
      </div>
    </details>
    """
  end

  def json_tree(%{data: d} = assigns) when is_list(d) do
    indexed = Enum.with_index(d)
    assigns = assign(assigns, :indexed, indexed)

    ~H"""
    <details open class="ml-2">
      <summary class="cursor-pointer hover:bg-base-200 rounded px-1">
        <%= if @name do %>
          <span class="text-info">"{@name}"</span><span class="text-base-content/60">: </span>
        <% end %>
        <span class="text-base-content/60">{list_summary(@indexed)}</span>
      </summary>
      <div class="ml-3 border-l border-base-300 pl-2">
        <.json_tree :for={{v, i} <- @indexed} data={v} name={"#{i}"} />
      </div>
    </details>
    """
  end

  def json_tree(%{data: d} = assigns) do
    type_class =
      cond do
        is_binary(d) -> "text-success"
        is_number(d) -> "text-warning"
        is_boolean(d) -> "text-secondary"
        is_nil(d) -> "text-error"
        true -> "text-base-content"
      end

    rendered =
      cond do
        is_nil(d) -> "null"
        is_binary(d) -> "\"#{d}\""
        true -> inspect(d)
      end

    assigns = assign(assigns, type_class: type_class, rendered: rendered)

    ~H"""
    <div class="ml-2 px-1">
      <%= if @name do %>
        <span class="text-info">"{@name}"</span><span class="text-base-content/60">: </span>
      <% end %>
      <span class={["font-mono", @type_class]}>{@rendered}</span>
    </div>
    """
  end

  defp map_summary(pairs) do
    n = length(pairs)
    "{#{n} #{if n == 1, do: "key", else: "keys"}}"
  end

  defp list_summary(items) do
    n = length(items)
    "[#{n} #{if n == 1, do: "item", else: "items"}]"
  end
end
