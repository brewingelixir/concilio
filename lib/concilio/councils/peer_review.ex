defmodule Concilio.Councils.PeerReview do
  @moduledoc """
  Three members analyse independently, then read each other's drafts in a peer-review round before the chair synthesizes. Surfaces disagreement before consensus.
  """

  use CouncilEx

  alias Concilio.Councils.Members.{Echo, Synthesizer}

  member(:alpha, Echo, provider: :openai, model: "gpt-4o-mini")
  member(:beta, Echo, provider: :openai, model: "gpt-4o-mini")
  member(:gamma, Echo, provider: :openai, model: "gpt-4o-mini")

  round(:independent_analysis)
  round(:peer_review)

  chair(Synthesizer, id: :synthesizer, provider: :openai, model: "gpt-4o-mini")

  def samples do
    [
      %{
        title: "Hiring process redesign",
        input:
          "Propose a hiring process for senior engineers that minimizes false negatives without ballooning cycle time."
      },
      %{
        title: "Reading list",
        input:
          "Recommend five books an engineering manager should read in their first year on the job, and why."
      }
    ]
  end
end
