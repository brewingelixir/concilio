defmodule Concilio.Councils.Quickstart do
  @moduledoc """
  Two-member panel (Advocate, Skeptic) + Synthesizer chair. Mirrors the council_ex README quickstart — a fast first taste of multi-model deliberation.
  """

  use CouncilEx

  alias Concilio.Councils.Members.{Advocate, Skeptic, Synthesizer}

  member(:advocate, Advocate, provider: :openai, model: "gpt-5.4-mini")
  member(:skeptic, Skeptic, provider: :openai, model: "gpt-5.4-mini")

  round(:independent_analysis)

  chair(Synthesizer, id: :synthesizer, provider: :openai, model: "gpt-5.4-mini")

  def samples do
    [
      %{
        title: "Remote work policy",
        input: "Should a 30-person engineering team go fully remote, hybrid, or in-office?"
      },
      %{
        title: "Adopt new tech",
        input:
          "We use Postgres + Elixir. Would adopting Kafka for our event log meaningfully help, or is it overkill at our scale?"
      }
    ]
  end
end
