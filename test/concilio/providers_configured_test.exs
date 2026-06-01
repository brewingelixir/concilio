defmodule Concilio.ProvidersConfiguredTest do
  use Concilio.DataCase, async: false

  alias Concilio.Providers

  setup do
    Application.put_env(:concilio, :concilio_secret, "ac-test-#{System.unique_integer()}")
    on_exit(fn -> Application.delete_env(:council_ex, :providers) end)
    :ok
  end

  describe "any_configured?/0" do
    test "false on a fresh DB" do
      refute Providers.any_configured?()
    end

    test "false when provider enabled but no creds" do
      {:ok, _} = Providers.set_enabled(:openai, true)
      refute Providers.any_configured?()
    end

    test "false when provider enabled + creds but no working-set models" do
      {:ok, _} = Providers.set_enabled(:openai, true)
      {:ok, _} = Providers.set_api_key(:openai, "sk-test")
      refute Providers.any_configured?()
    end

    test "true when provider enabled + creds + at least one working-set model" do
      {:ok, _} = Providers.set_enabled(:openai, true)
      {:ok, _} = Providers.set_api_key(:openai, "sk-test")
      {:ok, _} = Providers.add_user_model(:openai, "gpt-4o", in_working_set: true)

      assert Providers.any_configured?()
    end

    test "ollama counts without an api key" do
      {:ok, _} = Providers.set_enabled(:ollama, true)
      {:ok, _} = Providers.add_user_model(:ollama, "llama3.1:8b", in_working_set: true)

      assert Providers.any_configured?()
    end
  end
end
