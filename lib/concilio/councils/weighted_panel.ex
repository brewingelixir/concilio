defmodule Concilio.Councils.WeightedPanel do
  @moduledoc """
  Three Echo members analyse the question independently with self-reported confidence; the chair runs a weighted-synthesis round that merges drafts proportionally to each member's reported confidence. Use when you want stronger voices to dominate the synthesis without picking weights by hand.

  Implements the Wu et al. *Council Mode* weighted-consensus topology
  (arXiv:2604.02923) declaratively, so it is auto-discovered as a static
  template.
  """

  use CouncilEx

  alias Concilio.Councils.Members.{Echo, Synthesizer}

  member(:alpha, Echo, provider: :openai, model: "gpt-5.4-mini", confidence: :self_report)
  member(:beta, Echo, provider: :openai, model: "gpt-5.4-mini", confidence: :self_report)
  member(:gamma, Echo, provider: :openai, model: "gpt-5.4-mini", confidence: :self_report)

  round(:independent_analysis)
  round(CouncilEx.Rounds.WeightedSynthesis, expose_confidence: true)

  chair(Synthesizer, id: :synthesizer, provider: :openai, model: "gpt-5.4-mini")

  def samples do
    [
      %{
        title: "Estimate readers",
        input:
          "Roughly how many active English-language tech bloggers exist worldwide today? Show your reasoning."
      },
      %{
        title: "Best DB for analytics",
        input:
          "For a 50TB analytics workload with mostly read-only OLAP queries, which database family is the best default?"
      }
    ]
  end
end
