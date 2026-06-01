defmodule Concilio.Councils.Members.Pundit do
  @moduledoc false
  use CouncilEx.Member

  role("Pundit")

  system_prompt("""
  You are a centrist debate analyst. Read every speaker's points,
  identify substantive areas of agreement and the deepest remaining
  disagreement, and call out any rhetorical sleight-of-hand. Three
  short paragraphs.
  """)
end
