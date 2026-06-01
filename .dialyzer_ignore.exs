# Dialyzer warning ignores. Each entry is one of:
#
#   {file_path :: String.t()}
#   {file_path :: String.t(), warning :: atom()}
#   {file_path :: String.t(), warning :: atom(), line :: pos_integer()}
#
# Keep this list short and explain each entry; do not silence project
# code without a reason.

[
  # ── council_ex (hex dep) — fundamental macro layer ──────────────────
  #
  # CouncilEx.Council.InlineMember's macro emits `@attr || raise(...)`
  # fallbacks for fields the caller always provides at compile time
  # (model, system_prompt, role …). Every Concilio member fills these,
  # so the fallback is dead. False positive — and per kickoff §1 we
  # don't modify council_ex.
  #
  # Path entries match `to_string(file)` exactly. council_ex is a Hex
  # dependency, so its source lives under deps/.
  {"deps/council_ex/lib/council_ex/council/inline_member.ex", :guard_fail},

  # ── Concilio member modules (use CouncilEx.Member) ───────────────────
  #
  # CouncilEx.Member.__before_compile__/1 injects the same `@attr ||
  # raise(...)` pattern for role/system_prompt. Every member declares
  # both at compile time, so dialyzer flags the fallback as dead.
  {"lib/concilio/councils/members/advocate.ex", :guard_fail},
  {"lib/concilio/councils/members/con.ex", :guard_fail},
  {"lib/concilio/councils/members/conservative.ex", :guard_fail},
  {"lib/concilio/councils/members/echo.ex", :guard_fail},
  {"lib/concilio/councils/members/judge.ex", :guard_fail},
  {"lib/concilio/councils/members/liberal.ex", :guard_fail},
  {"lib/concilio/councils/members/libertarian.ex", :guard_fail},
  {"lib/concilio/councils/members/moderator.ex", :guard_fail},
  {"lib/concilio/councils/members/optimist.ex", :guard_fail},
  {"lib/concilio/councils/members/pr_synth.ex", :guard_fail},
  {"lib/concilio/councils/members/pragmatist.ex", :guard_fail},
  {"lib/concilio/councils/members/pro.ex", :guard_fail},
  {"lib/concilio/councils/members/progressive.ex", :guard_fail},
  {"lib/concilio/councils/members/pundit.ex", :guard_fail},
  {"lib/concilio/councils/members/skeptic.ex", :guard_fail},
  {"lib/concilio/councils/members/synthesizer.ex", :guard_fail},
  {"lib/concilio/councils/members/writer.ex", :guard_fail},

  # ── Concilio static councils (use CouncilEx) ─────────────────────────
  #
  # CouncilEx's `chair/2` and member DSL emit branches with `nil`
  # fallbacks dialyzer thinks are dead given the literal arguments.
  # False positive from the same macro family.
  {"lib/concilio/councils/creative_judge.ex", :pattern_match},
  {"lib/concilio/councils/critique.ex", :pattern_match},
  {"lib/concilio/councils/debate.ex", :pattern_match},
  {"lib/concilio/councils/demo.ex", :pattern_match},
  {"lib/concilio/councils/iterative.ex", :pattern_match},
  {"lib/concilio/councils/jury.ex", :pattern_match},
  {"lib/concilio/councils/multi_model_panel.ex", :pattern_match},
  {"lib/concilio/councils/parallel_panel.ex", :pattern_match},
  {"lib/concilio/councils/peer_review.ex", :pattern_match},
  {"lib/concilio/councils/pr_review.ex", :pattern_match},
  {"lib/concilio/councils/presidential_debate.ex", :pattern_match},
  {"lib/concilio/councils/quickstart.ex", :pattern_match},
  {"lib/concilio/councils/weighted_panel.ex", :pattern_match}
]
