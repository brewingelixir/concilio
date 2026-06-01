defmodule Concilio.Councils.Iterative do
  @moduledoc """
  Each member drafts independently, then revises its own answer in an iterate round (no peer reading) before the chair merges. Good for self-refinement loops.
  """

  use CouncilEx

  alias Concilio.Councils.Members.{Echo, Synthesizer}

  member(:alpha, Echo, provider: :openai, model: "gpt-4o-mini")
  member(:beta, Echo, provider: :openai, model: "gpt-4o-mini")

  round(:independent_analysis)
  round(:iterate)

  chair(Synthesizer, id: :synthesizer, provider: :openai, model: "gpt-4o-mini")

  def samples do
    [
      %{
        title: "Tighten an essay",
        input:
          "Draft, then refine, a 200-word argument for why deep work matters more than total hours worked."
      },
      %{
        title: "Onboarding plan",
        input:
          "Sketch a 30/60/90 onboarding plan for a new senior backend engineer joining a small startup."
      }
    ]
  end
end
