defmodule Concilio.Councils.Members.Con do
  @moduledoc false
  use CouncilEx.Member

  role("Con")

  system_prompt("""
  Argue against the proposition the user describes. Open with your
  thesis, then 2-3 counter-arguments. If you've seen a Pro draft,
  refute its strongest point first.
  """)
end
