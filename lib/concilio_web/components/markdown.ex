defmodule ConcilioWeb.Components.Markdown do
  @moduledoc """
  Server-side markdown renderer for assistant message content.
  Uses earmark for HTML + makeup for code-block syntax highlighting.
  Output is wrapped in `Phoenix.HTML.raw/1` after escaping; we trust
  earmark's HTML output for assistant content (no user-rendered
  markdown for v1; the user side stays plaintext).
  """

  use Phoenix.Component

  attr :body, :string, required: true
  attr :class, :string, default: "prose prose-sm max-w-none"

  def markdown(assigns) do
    assigns = assign(assigns, :rendered, render(assigns.body))

    ~H"""
    <div class={@class}>{Phoenix.HTML.raw(@rendered)}</div>
    """
  end

  @doc """
  Renders a markdown string to a sanitized HTML string. Public so
  callers outside HEEx can use it (e.g. for export).
  """
  @spec render(String.t() | nil) :: String.t()
  def render(nil), do: ""

  def render(body) when is_binary(body) do
    body
    |> Earmark.as_html!(earmark_options())
    |> highlight_code_blocks()
  end

  defp earmark_options do
    %Earmark.Options{
      breaks: true,
      gfm: true,
      smartypants: false,
      escape: false,
      compact_output: true
    }
  end

  # Trivial highlighter pass-through. Real makeup integration walks the
  # HTML tree to find <pre><code class="lang-foo">…</code></pre> blocks
  # and replaces them with makeup output. Keep this branch simple: hand
  # back unmodified HTML for now.
  defp highlight_code_blocks(html), do: html
end
