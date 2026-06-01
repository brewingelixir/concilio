defmodule Concilio.Councils.Jury do
  @moduledoc """
  Three Echo judges run an independent-analysis round in parallel with self-reported confidence; if average confidence falls below 0.75, the round re-samples (up to 2 iterations total) before the chair synthesizes the final verdict. Judges never see each other's answers across iterations — independent re-sampling, not debate.

  Implements the K=3 jury-with-retry topology from Wu et al. *Can LLM
  Agents Really Debate?* (arXiv:2511.07784) declaratively, so it is
  auto-discovered as a static template. Independence across iterations
  is intentional — the paper finds visible peer answers induce
  conformity rather than correctness.
  """

  use CouncilEx

  alias Concilio.Councils.Members.{Echo, Synthesizer}

  member(:judge_alpha, Echo, provider: :openai, model: "gpt-4o-mini", confidence: :self_report)
  member(:judge_beta, Echo, provider: :openai, model: "gpt-4o-mini", confidence: :self_report)
  member(:judge_gamma, Echo, provider: :openai, model: "gpt-4o-mini", confidence: :self_report)

  @doc false
  def __jury_converged__(_prev, %CouncilEx.RoundResult{member_results: mrs}) do
    confs =
      for {_id, %CouncilEx.MemberResult{status: :ok, confidence: c}} <- mrs,
          is_number(c),
          do: c

    case confs do
      [] -> false
      list -> Enum.sum(list) / length(list) >= 0.75
    end
  end

  round(CouncilEx.Rounds.Iterate,
    wrap: :independent_analysis,
    until: &__MODULE__.__jury_converged__/2,
    max_iterations: 2
  )

  chair(Synthesizer, id: :synthesizer, provider: :openai, model: "gpt-4o-mini")

  def samples do
    [
      %{
        title: "Verdict on layoffs",
        input:
          "A profitable startup laid off 10% of staff to widen margins ahead of fundraising. Was the decision sound?"
      },
      %{
        title: "Did the AI hallucinate?",
        input:
          "An LLM answered: 'The capital of Australia is Sydney.' Render a verdict on whether the answer is correct, with reasoning."
      }
    ]
  end
end
