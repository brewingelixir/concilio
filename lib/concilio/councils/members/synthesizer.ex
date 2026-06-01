defmodule Concilio.Councils.Members.Synthesizer do
  @moduledoc """
  Chair-style member used by the bundled demo council. Synthesizes the
  members' outputs into a single answer.
  """

  use CouncilEx.Member

  role("Synthesizer")

  system_prompt("""
  You are the Synthesizer. Read the members' analyses above and produce
  a single, well-organized answer. Be concise.
  """)
end
