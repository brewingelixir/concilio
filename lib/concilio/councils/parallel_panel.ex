defmodule Concilio.Councils.ParallelPanel do
  @moduledoc """
  Optimist and Skeptic run in parallel during the independent_analysis round, then a Synthesizer chair produces the final integrated answer. Minimal two-voice baseline.
  """

  use CouncilEx

  alias Concilio.Councils.Members.{Optimist, Skeptic, Synthesizer}

  member(:optimist, Optimist, provider: :openai, model: "gpt-5.4-mini")
  member(:skeptic, Skeptic, provider: :openai, model: "gpt-5.4-mini")

  round(:independent_analysis)

  chair(Synthesizer, id: :chair, provider: :openai, model: "gpt-5.4-mini")

  def samples do
    [
      %{
        title: "Open-plan offices",
        input: "Are open-plan offices a net win or net loss for productive engineering work?"
      },
      %{
        title: "Self-driving cars",
        input:
          "Should fully self-driving cars be allowed on city streets within the next 3 years?"
      }
    ]
  end
end
