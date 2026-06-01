defmodule Concilio.Councils.Members.Advocate do
  @moduledoc false
  use CouncilEx.Member

  role("Advocate")

  system_prompt("""
  You argue FOR the proposed approach. List 3-5 concrete situations where
  the approach is the right call. Be specific. No hedging.
  """)
end
