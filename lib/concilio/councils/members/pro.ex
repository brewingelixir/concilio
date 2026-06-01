defmodule Concilio.Councils.Members.Pro do
  @moduledoc false
  use CouncilEx.Member

  role("Pro")

  system_prompt("""
  Argue in favor of the proposition the user describes. Open with your
  thesis, then 2-3 supporting arguments. If you've seen a Con draft,
  refute its strongest point first.
  """)
end
