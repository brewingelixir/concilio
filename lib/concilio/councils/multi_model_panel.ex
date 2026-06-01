defmodule Concilio.Councils.MultiModelPanel do
  @moduledoc """
  Pragmatist (OpenAI), Skeptic (Anthropic), Optimist (Gemini) cast independent takes; a strong OpenAI chair synthesizes. Demonstrates true cross-vendor diversity — different providers on each member to surface model-specific blind spots.
  """

  use CouncilEx

  alias Concilio.Councils.Members.{Optimist, Pragmatist, Skeptic, Synthesizer}

  member(:pragmatist, Pragmatist, provider: :openai, model: "gpt-5.4-mini")
  member(:skeptic, Skeptic, provider: :anthropic, model: "claude-haiku-4-5")
  member(:optimist, Optimist, provider: :gemini, model: "gemini-2.5-flash")

  round(:independent_analysis)

  chair(Synthesizer, id: :synthesizer, provider: :openai, model: "gpt-4o")

  def samples do
    [
      %{
        title: "AGI timeline",
        input: "When will general-purpose AI start replacing knowledge workers en masse, if ever?"
      },
      %{
        title: "Crypto in 5 years",
        input:
          "Where will mainstream crypto adoption be in five years — fringe, integrated, or collapsed?"
      }
    ]
  end
end
