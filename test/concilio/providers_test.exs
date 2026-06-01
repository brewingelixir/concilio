defmodule Concilio.ProvidersTest do
  use Concilio.DataCase, async: false

  alias Concilio.Providers
  alias Concilio.Providers.Model

  setup do
    Application.put_env(:concilio, :concilio_secret, "providers-test-#{System.unique_integer()}")
    :ok
  end

  describe "settings" do
    test "set_enabled toggles" do
      {:ok, s1} = Providers.set_enabled(:openai, true)
      assert s1.enabled
      {:ok, s2} = Providers.set_enabled(:openai, false)
      refute s2.enabled
    end

    test "set/get_api_key round-trips through encryption" do
      {:ok, _} = Providers.set_api_key(:openai, "sk-abc-123")
      assert {:ok, "sk-abc-123"} = Providers.get_api_key(:openai)
    end

    test "clearing the api key returns :missing" do
      {:ok, _} = Providers.set_api_key(:openai, "x")
      {:ok, _} = Providers.set_api_key(:openai, nil)
      assert :missing = Providers.get_api_key(:openai)
    end

    test "set_endpoint_override stores and clears" do
      {:ok, _} = Providers.set_endpoint_override(:openai, "https://proxy.local/v1")
      [setting] = Providers.list_settings() |> Enum.filter(&(&1.provider == :openai))
      assert setting.endpoint_override == "https://proxy.local/v1"

      {:ok, _} = Providers.set_endpoint_override(:openai, nil)
      [setting] = Providers.list_settings() |> Enum.filter(&(&1.provider == :openai))
      assert setting.endpoint_override == nil
    end
  end

  describe "models" do
    test "add_user_model + list_models" do
      {:ok, m} = Providers.add_user_model(:openrouter, "vendor/model-x")
      assert %Model{provider: :openrouter, model_id: "vendor/model-x", source: :user_added} = m
      assert m.in_working_set
      assert [^m] = Providers.list_models(:openrouter)
    end

    test "toggle_in_working_set flips the boolean" do
      {:ok, m} = Providers.add_user_model(:openrouter, "x/y")
      {:ok, m2} = Providers.toggle_in_working_set(m)
      refute m2.in_working_set
    end

    test "list_working_set_models filters" do
      {:ok, _} = Providers.add_user_model(:openrouter, "a/in", in_working_set: true)
      {:ok, m} = Providers.add_user_model(:openrouter, "a/out", in_working_set: false)

      ws_ids = Providers.list_working_set_models() |> Enum.map(& &1.model_id)
      assert "a/in" in ws_ids
      refute "a/out" in ws_ids
      refute m.in_working_set
    end

    test "record_test_result persists status + latency + error" do
      {:ok, m} = Providers.add_user_model(:openrouter, "ping/test")

      {:ok, m2} =
        Providers.record_test_result(m, %{status: :error, latency_ms: 42, error: "boom"})

      assert m2.last_test_status == :error
      assert m2.last_test_latency_ms == 42
      assert m2.last_test_error == "boom"
      assert m2.last_test_at
    end
  end

  describe "sync_bundled_catalog!/0" do
    test "is idempotent and inserts bundled rows" do
      first = Providers.sync_bundled_catalog!()
      assert first.inserted > 0

      second = Providers.sync_bundled_catalog!()
      assert second.inserted == 0
    end
  end
end
