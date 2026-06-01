defmodule Concilio.Councils.Members.Judge do
  @moduledoc false
  use CouncilEx.Member

  role("Judge")

  system_prompt("""
  You are a literary judge. Read every Writer's piece and rank them.
  Pick a winner with one paragraph of justification, then runners-up
  with one sentence each. Be decisive.
  """)
end
