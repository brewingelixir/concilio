defmodule Concilio.Providers.RuntimeTest do
  use Concilio.DataCase, async: false

  alias Concilio.Providers
  alias Concilio.Providers.Runtime

  setup do
    Application.put_env(:concilio, :concilio_secret, "rt-test-#{System.unique_integer()}")

    # Reset the council_ex providers slot per test.
    on_exit(fn -> Application.delete_env(:council_ex, :providers) end)
    Application.put_env(:council_ex, :providers, [])
    :ok
  end

  test "refresh!/0 with no enabled providers writes an empty list" do
    assert [] = Runtime.refresh!()
    assert [] = Application.get_env(:council_ex, :providers, [])
  end

  test "skips providers without credentials" do
    {:ok, _} = Providers.set_enabled(:openai, true)

    list = Runtime.refresh!()
    assert list == []
  end

  test "writes a complete entry for an enabled provider with credentials" do
    {:ok, _} = Providers.set_enabled(:openai, true)
    {:ok, _} = Providers.set_api_key(:openai, "sk-test-123")

    list = Runtime.refresh!()
    assert [openai: opts] = list
    assert opts[:api_key] == "sk-test-123"
    assert opts[:adapter] == CouncilEx.Provider.Adapters.OpenAI
    refute Keyword.has_key?(opts, :dispatcher)
  end

  test "set_api_key/2 auto-refreshes the runtime env" do
    {:ok, _} = Providers.set_enabled(:openrouter, true)
    {:ok, _} = Providers.set_api_key(:openrouter, "sk-or-456")

    [openrouter: opts] = Application.get_env(:council_ex, :providers)
    assert opts[:api_key] == "sk-or-456"
  end

  test "set_enabled/2 false drops the provider from the runtime list" do
    {:ok, _} = Providers.set_enabled(:openai, true)
    {:ok, _} = Providers.set_api_key(:openai, "sk-x")
    assert [openai: _] = Application.get_env(:council_ex, :providers)

    {:ok, _} = Providers.set_enabled(:openai, false)
    assert [] = Application.get_env(:council_ex, :providers)
  end

  test "set_endpoint_override/2 sets :base_url" do
    {:ok, _} = Providers.set_enabled(:openai, true)
    {:ok, _} = Providers.set_api_key(:openai, "sk-x")
    {:ok, _} = Providers.set_endpoint_override(:openai, "https://proxy.example/v1")

    [openai: opts] = Application.get_env(:council_ex, :providers)
    assert opts[:base_url] == "https://proxy.example/v1"
  end

  test "ollama works without an api key" do
    {:ok, _} = Providers.set_enabled(:ollama, true)

    [ollama: opts] = Runtime.refresh!()
    # Ollama is a preset over the OpenAI-compat adapter, not a standalone adapter
    assert opts[:adapter] == CouncilEx.Provider.Adapters.OpenAI
    refute Keyword.has_key?(opts, :dispatcher)
    assert is_binary(opts[:base_url])
  end
end
