defmodule ConcilioWeb.RunIndexLive do
  @moduledoc """
  Skeleton runs index. Filters land at M3.
  """

  use ConcilioWeb, :live_view

  alias Concilio.Runs

  @impl true
  def mount(_params, _session, socket) do
    runs = Runs.list(limit: 50)

    {:ok,
     socket
     |> assign(:page_title, "Runs")
     |> stream(:runs, runs)}
  end

  defp status_badge(:ok), do: "badge-success"
  defp status_badge(:partial), do: "badge-warning"
  defp status_badge(:error), do: "badge-error"
  defp status_badge(:cancelled), do: "badge-ghost"
  defp status_badge(:running), do: "badge-info"
  defp status_badge(_), do: "badge-ghost"

  defp format_ms(nil), do: "—"
  defp format_ms(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_ms(ms), do: "#{Float.round(ms / 1_000, 1)}s"

  defp format_cost(nil), do: "—"
  defp format_cost(0), do: "<$0.01"

  defp format_cost(cents) when is_integer(cents) and cents < 100,
    do: "$0.#{String.pad_leading(Integer.to_string(cents), 2, "0")}"

  defp format_cost(cents) when is_integer(cents) do
    dollars = div(cents, 100)
    rest = rem(cents, 100)
    "$#{dollars}.#{String.pad_leading(Integer.to_string(rest), 2, "0")}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} max_w="max-w-6xl">
      <div class="space-y-6">
        <div class="flex items-baseline justify-between">
          <div>
            <h1 class="text-2xl font-semibold">Runs</h1>
            <p class="text-sm text-base-content/60 mt-1">
              Every council execution, replayable and re-runnable.
            </p>
          </div>
          <.link navigate={~p"/councils"} class="btn btn-ghost btn-sm">← Councils</.link>
        </div>

        <div class="card bg-base-100 border border-base-300 overflow-hidden">
          <table class="table table-sm">
            <thead>
              <tr class="text-xs text-base-content/60">
                <th>Run id</th>
                <th>Council</th>
                <th>Status</th>
                <th class="text-right">Duration</th>
                <th class="text-right">Cost</th>
              </tr>
            </thead>
            <tbody id="runs" phx-update="stream">
              <tr :for={{dom_id, run} <- @streams.runs} id={dom_id} class="hover">
                <td class="font-mono text-xs whitespace-nowrap">
                  <.link navigate={~p"/runs/#{run.id}"} class="link link-hover">
                    {run.run_id}
                  </.link>
                </td>
                <td class="text-sm">{run.template.name}</td>
                <td>
                  <span class={["badge badge-sm", status_badge(run.status)]}>{run.status}</span>
                </td>
                <td class="text-right text-xs font-mono">
                  {format_ms(run.total_duration_ms)}
                </td>
                <td class="text-right text-xs font-mono">
                  {format_cost(run.total_cost_cents)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
