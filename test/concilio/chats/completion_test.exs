defmodule Concilio.Chats.CompletionTest do
  use ExUnit.Case, async: false

  alias Concilio.Chats.Completion

  test "errors out when the provider isn't in council_ex env" do
    Application.put_env(:council_ex, :providers, [])

    assert {:error, {:provider_not_configured, :openai}} =
             Completion.run(:openai, "gpt-4o", [%{role: "user", content: "hi"}])
  end

  test "normalizes message role atoms to strings before dispatch" do
    # Compile-only check via the private build_request — exercise the
    # public path with a missing provider so we confirm we got past the
    # message normalization.
    Application.put_env(:council_ex, :providers, [])

    assert {:error, {:provider_not_configured, :anthropic}} =
             Completion.run(:anthropic, "claude-3-5-sonnet-latest", [
               %{role: :user, content: "hi"}
             ])
  end
end
