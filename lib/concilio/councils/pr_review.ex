defmodule Concilio.Councils.PrReview do
  @moduledoc """
  Three reviewers (security, performance, style) read a PR diff in
  parallel; three cross-vendor judges then vote on the merge decision
  via plurality; a chair writes the final verdict comment quoting the
  tally and most material analyst finding.

  Demonstrates the **analyst → judge → chair** topology: per-round
  routers split which members participate per round so analysts never
  vote and judges never analyze. Judges declare
  `output_schema CouncilEx.Schemas.Vote` so
  `CouncilEx.Aggregators.Plurality` can read the `:choice` field
  (`"merge" | "needs_changes" | "block"`).

  Cross-vendor judges (OpenAI / Anthropic / Gemini) follow Wu et al.
  *Can LLM Agents Really Debate?* (arXiv:2511.07784): diversity beats
  structure, and judges do not see each other's votes within the
  round.

  Members are inlined here because they are not reused elsewhere. The
  chair stays as a separate `Concilio.Councils.Members.PrSynth` module
  because the `chair/2` DSL requires a module reference.
  """

  use CouncilEx

  alias Concilio.Councils.Members.PrSynth

  member :sec do
    role("Security Reviewer")
    provider(:openai)
    model("gpt-4o-mini")

    system_prompt("""
    You are a security reviewer reading a pull request diff. List concrete
    security issues only: injection, auth/authz, secret handling, crypto
    misuse, deserialization, SSRF, path traversal, missing validation at
    trust boundaries.

    For each issue: one sentence + the offending line or symbol. Be
    specific. No generic advice. If the diff is clean, say "No issues
    found." and stop.
    """)
  end

  member :perf do
    role("Performance Reviewer")
    provider(:openai)
    model("gpt-4o-mini")

    system_prompt("""
    You are a performance reviewer reading a pull request diff. Flag
    concrete performance issues only: N+1 queries, missing indexes,
    unbounded recursion, large allocations on hot paths, sync calls in
    request lifecycles, blocking calls inside reduces.

    For each issue: one sentence + the offending line or symbol. No
    micro-optimizations or speculative concerns. If the diff is clean,
    say "No issues found." and stop.
    """)
  end

  member :style do
    role("Style Reviewer")
    provider(:openai)
    model("gpt-4o-mini")

    system_prompt("""
    You are a style and maintainability reviewer reading a pull request
    diff. Flag concrete issues only: misleading names, dead code, missing
    or stale docs on public surfaces, magic numbers, premature
    abstractions, copy-pasted blocks, broken project conventions.

    For each issue: one sentence + the offending line or symbol. No
    bikeshedding on whitespace or import order. If the diff is clean,
    say "No issues found." and stop.
    """)
  end

  @judge_prompt """
  You are a pull request judge. Read the security, performance, and
  style reviewers' findings (already provided above) and decide.

  Vote exactly one of:
    * "merge" — no material issues, ship it.
    * "needs_changes" — material issues that the author can address
      without rethinking the design.
    * "block" — design-level or correctness flaws that require
      reconsidering the change.

  Provide a one-line rationale referencing which reviewer's finding
  drove your decision. Set confidence between 0.0 and 1.0 reflecting
  how clear-cut the call is.
  """

  member :j_gpt do
    role("PR Judge (GPT)")
    provider(:openai)
    model("gpt-4o")
    system_prompt(@judge_prompt)
    output_schema(CouncilEx.Schemas.Vote)
  end

  member :j_claude do
    role("PR Judge (Claude)")
    provider(:anthropic)
    model("claude-haiku-4-5")
    system_prompt(@judge_prompt)
    output_schema(CouncilEx.Schemas.Vote)
  end

  member :j_gemini do
    role("PR Judge (Gemini)")
    provider(:gemini)
    model("gemini-2.5-flash")
    system_prompt(@judge_prompt)
    output_schema(CouncilEx.Schemas.Vote)
  end

  round(:independent_analysis, router: &__MODULE__.__analysts__/2)

  round(:vote,
    router: &__MODULE__.__judges__/2,
    aggregator: CouncilEx.Aggregators.Plurality
  )

  chair(PrSynth, id: :verdict, provider: :openai, model: "gpt-4o")

  @doc false
  def __analysts__(_input, _ctx), do: [:sec, :perf, :style]

  @doc false
  def __judges__(_input, _ctx), do: [:j_gpt, :j_claude, :j_gemini]

  def samples do
    [
      %{
        title: "Tiny refactor diff",
        input: """
        diff --git a/lib/users.ex b/lib/users.ex
        @@
        -  def find(id), do: Repo.get(User, id)
        +  def find(id) when is_integer(id), do: Repo.get(User, id)
        +  def find(id) when is_binary(id), do: Repo.get_by(User, email: id)
        """
      },
      %{
        title: "Risky auth change",
        input: """
        diff --git a/lib/auth.ex b/lib/auth.ex
        @@
        -  def verify_token(token), do: Token.verify(token, max_age: 3600)
        +  def verify_token(token), do: Token.verify(token, max_age: :infinity)
        """
      }
    ]
  end
end
