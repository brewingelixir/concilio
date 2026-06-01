defmodule Concilio.Councils.PresidentialDebate do
  @moduledoc """
  Four ideological personas (Liberal, Conservative, Progressive, Libertarian) debate across two chained peer-review rounds; a centrist Pundit chair synthesizes points of agreement and the deepest remaining disagreement.
  """

  use CouncilEx

  alias Concilio.Councils.Members.{
    Conservative,
    Liberal,
    Libertarian,
    Progressive,
    Pundit
  }

  member(:liberal, Liberal, provider: :openai, model: "gpt-4o-mini")
  member(:conservative, Conservative, provider: :openai, model: "gpt-4o-mini")
  member(:progressive, Progressive, provider: :openai, model: "gpt-4o-mini")
  member(:libertarian, Libertarian, provider: :openai, model: "gpt-4o-mini")

  round(:independent_analysis)
  round(:peer_review)
  round(:peer_review)

  chair(Pundit, id: :pundit, provider: :openai, model: "gpt-4o")

  def samples do
    [
      %{
        title: "Universal basic income",
        input: "Should the federal government adopt a universal basic income?"
      },
      %{
        title: "Public healthcare",
        input: "Should the country move to a single-payer public healthcare system?"
      }
    ]
  end
end
