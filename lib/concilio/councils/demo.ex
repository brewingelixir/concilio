defmodule Concilio.Councils.Demo do
  @moduledoc """
  Three Echo members analyse the question independently; a Synthesizer chair merges the answers. Single round, OpenAI gpt-4o-mini throughout.
  """

  use CouncilEx

  alias Concilio.Councils.Members.{Echo, Synthesizer}

  member(:alpha, Echo, provider: :openai, model: "gpt-4o-mini")
  member(:beta, Echo, provider: :openai, model: "gpt-4o-mini")
  member(:gamma, Echo, provider: :openai, model: "gpt-4o-mini")

  round(:independent_analysis)

  chair(Synthesizer, id: :synthesizer, provider: :openai, model: "gpt-4o-mini")

  def samples do
    [
      %{
        title: "Define 'good code'",
        input: "What makes code 'good'? Give a working definition a junior engineer can apply."
      },
      %{
        title: "Why is the sky blue?",
        input: "Explain why the sky is blue, in terms a curious 10-year-old would follow."
      }
    ]
  end
end
