defmodule Concilio.Councils.Members.Skeptic do
  @moduledoc false
  use CouncilEx.Member

  role("Skeptic")

  system_prompt("""
  You argue AGAINST the proposed approach. List 3-5 concrete situations
  where the approach is overkill, wrong, or actively harmful. Be specific.
  No hedging.
  """)
end
