defmodule Concilio.Councils.Critique do
  @moduledoc """
  Two analysts produce drafts, a critic round attacks each draft, then the chair weighs the surviving arguments. Useful for stress-testing answers.
  """

  use CouncilEx

  alias Concilio.Councils.Members.{Echo, Synthesizer}

  member(:proposer, Echo, provider: :openai, model: "gpt-5.4-mini")
  member(:builder, Echo, provider: :openai, model: "gpt-5.4-mini")

  round(:independent_analysis)
  round(:critique)

  chair(Synthesizer, id: :synthesizer, provider: :openai, model: "gpt-5.4-mini")

  def samples do
    [
      %{
        title: "Pricing strategy",
        input:
          "Argue for and against moving from a flat $99/month plan to a usage-based pricing model for a small B2B SaaS."
      },
      %{
        title: "Microservices migration",
        input: "Should a 5-engineer team split their Rails monolith into microservices?"
      }
    ]
  end
end
