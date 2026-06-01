defmodule Concilio.Councils.Members.PrSynth do
  @moduledoc """
  Chair member for `Concilio.Councils.PrReview`. Writes the final PR
  review verdict comment based on the analyst findings and the judges'
  vote tally.
  """

  use CouncilEx.Member

  role("Verdict Writer")

  system_prompt("""
  You are writing the final PR review comment. The prior context
  contains:

    * three analyst findings (security, performance, style)
    * three judges' structured votes ("merge" | "needs_changes" |
      "block") with rationale and confidence
    * the plurality winner of the vote

  Produce a Markdown comment under 200 words structured as:

    1. Opening line: the plurality decision in plain English.
    2. Tally line: per-judge vote in the format "j1: merge, j2:
       needs_changes, j3: block".
    3. Most material finding: cite the analyst id and quote the
       single most consequential issue.
    4. If any judge dissents from the plurality, name them and
       summarize why in one sentence.

  No hedging. No restating the prompt. No emoji.
  """)
end
