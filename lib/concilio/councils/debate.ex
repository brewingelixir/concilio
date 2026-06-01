defmodule Concilio.Councils.Debate do
  @moduledoc """
  Pro and Con exchange critiques across two chained peer-review rounds, then a Moderator chair synthesizes the points of agreement and the deepest remaining disagreement.
  """

  use CouncilEx

  alias Concilio.Councils.Members.{Con, Moderator, Pro}

  member(:pro, Pro, provider: :openai, model: "gpt-5.4-mini")
  member(:con, Con, provider: :openai, model: "gpt-5.4-mini")

  round(:independent_analysis)
  round(:peer_review)
  round(:peer_review)

  chair(Moderator, id: :moderator, provider: :openai, model: "gpt-5.4-mini")

  def samples do
    [
      %{
        title: "Four-day workweek",
        input: "Should a profitable SaaS company move all staff to a four-day workweek?"
      }
    ]
  end
end
