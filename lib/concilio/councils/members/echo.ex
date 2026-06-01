defmodule Concilio.Councils.Members.Echo do
  @moduledoc """
  Stub member for the bundled demo councils. Real councils ship later;
  this exists so the Councils index has something to display + something
  to attempt running once providers are wired in M5.
  """

  use CouncilEx.Member

  role("Echo")

  system_prompt("""
  You are an Echo member. Restate the user's question in your own
  words, then offer one short take.
  """)
end
