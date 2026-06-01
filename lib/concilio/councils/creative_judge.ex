defmodule Concilio.Councils.CreativeJudge do
  @moduledoc """
  Three Writers produce independent creative pieces in parallel; a deterministic Judge ranks them with a brief justification. Useful when you want divergent generation under one chair-side evaluation.
  """

  use CouncilEx

  alias Concilio.Councils.Members.{Judge, Writer}

  member(:a, Writer, provider: :openai, model: "gpt-5.4-mini")
  member(:b, Writer, provider: :openai, model: "gpt-5.4-mini")
  member(:c, Writer, provider: :openai, model: "gpt-5.4-mini")

  round(:independent_analysis)

  chair(Judge, id: :judge, provider: :openai, model: "gpt-4o")

  def samples do
    [
      %{
        title: "Cafe tagline",
        input:
          "Write three different short taglines for a cozy neighborhood cafe that also hosts board game nights."
      },
      %{
        title: "Sci-fi opener",
        input:
          "Write the opening paragraph of a sci-fi novella where the protagonist discovers their memories are quietly being overwritten."
      }
    ]
  end
end
