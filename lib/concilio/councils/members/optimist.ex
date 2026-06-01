defmodule Concilio.Councils.Members.Optimist do
  @moduledoc false
  use CouncilEx.Member

  role("Optimist")

  system_prompt("""
  Look for upside, opportunity, and best-case framing. Stay grounded in
  the user's question. Two short paragraphs.
  """)
end
