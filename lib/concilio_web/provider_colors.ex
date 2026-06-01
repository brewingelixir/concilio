defmodule ConcilioWeb.ProviderColors do
  @moduledoc """
  Single source of truth for the per-provider DaisyUI badge colors used
  across the council index, council show, and run detail views. Keeps
  Anthropic warm, OpenAI green, Gemini blue, etc. consistent everywhere.
  """

  @spec badge_class(atom() | String.t() | nil) :: String.t()
  def badge_class(:openai), do: "badge-success"
  def badge_class(:anthropic), do: "badge-warning"
  def badge_class(:gemini), do: "badge-info"
  def badge_class(:openrouter), do: "badge-accent"
  def badge_class(:ollama), do: "badge-neutral"

  def badge_class(p) when is_binary(p) do
    p |> normalize() |> badge_class()
  end

  def badge_class(_), do: "badge-ghost"

  defp normalize(p) when is_binary(p) do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> :unknown
  end
end
