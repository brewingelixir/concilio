defmodule Concilio.Chats.CouncilRefs do
  @moduledoc """
  Inline `[council:<run-uuid>]` references inside chat messages.

  Users insert these tokens via the "Quote in reply" button on a council
  bubble; they are persisted verbatim on the user message row. At history
  build time (or before passing a council summon's `:question`), the
  tokens are expanded into a quoted block carrying the chair's final
  synthesis so the downstream model can ground its reply on the actual
  council outcome rather than the opaque token.

  The token format is `[council:<runs.id>]` where `runs.id` is the
  binary_id PK (same id used by `~p"/runs/:id"`). Falls back to a
  placeholder when the run is missing or hasn't reached a terminal
  state.
  """

  alias Concilio.Runs

  @token_re ~r/\[council:([0-9a-fA-F-]{8,36})\]/

  @doc "Render a token referencing the given run id (UUID)."
  @spec token_for(String.t()) :: String.t()
  def token_for(run_id) when is_binary(run_id), do: "[council:" <> run_id <> "]"

  @doc """
  Replace every `[council:<id>]` occurrence in `text` with a quoted
  block containing the run's chair synthesis. Unknown / pending runs
  are replaced with a short placeholder.
  """
  @spec expand(nil) :: nil
  @spec expand(String.t()) :: String.t()
  def expand(nil), do: nil

  def expand(text) when is_binary(text) do
    Regex.replace(@token_re, text, fn _full, id -> render_ref(id) end)
  end

  defp render_ref(id) do
    case fetch_run(id) do
      nil ->
        "[council ref unavailable]"

      run ->
        case run.result_json do
          %{"final" => %{"content" => c}} when is_binary(c) and c != "" ->
            "\n" <> quoted_block(c, run) <> "\n"

          _ ->
            "[council ref pending]"
        end
    end
  end

  defp fetch_run(id) do
    Runs.get!(id)
  rescue
    Ecto.NoResultsError -> nil
    Ecto.Query.CastError -> nil
  end

  defp quoted_block(content, run) do
    header = "> [council synthesis · #{format_when(run)}]"

    body =
      content
      |> String.split("\n")
      |> Enum.map_join("\n", &("> " <> &1))

    header <> "\n" <> body
  end

  defp format_when(%{started_at: %DateTime{} = dt}),
    do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  defp format_when(_), do: "—"
end
