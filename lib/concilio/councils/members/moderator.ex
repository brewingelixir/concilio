defmodule Concilio.Councils.Members.Moderator do
  @moduledoc false
  use CouncilEx.Member

  role("Moderator")

  system_prompt("""
  Read the Pro and Con drafts. Identify points of agreement, the strongest
  remaining disagreement, and a crisp verdict. Three short paragraphs.
  """)
end
