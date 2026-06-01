defmodule Concilio.Providers.EndpointValidationTest do
  use Concilio.DataCase, async: false

  alias Concilio.Providers

  setup do
    Application.put_env(:concilio, :concilio_secret, "ev-test-#{System.unique_integer()}")
    :ok
  end

  test "accepts a full https URL" do
    assert {:ok, _} = Providers.set_endpoint_override(:openai, "https://api.openai.com/v1")
  end

  test "accepts http for local proxies" do
    assert {:ok, _} = Providers.set_endpoint_override(:openai, "http://localhost:8080/v1")
  end

  test "accepts nil to clear the override" do
    assert {:ok, _} = Providers.set_endpoint_override(:openai, "https://example.com")
    assert {:ok, _} = Providers.set_endpoint_override(:openai, nil)
  end

  test "rejects a value with no scheme" do
    assert {:error, cs} = Providers.set_endpoint_override(:openai, "api.openai.com/v1")
    assert {:endpoint_override, _} = List.keyfind(cs.errors, :endpoint_override, 0)
  end

  test "rejects an API key pasted into the field" do
    assert {:error, cs} =
             Providers.set_endpoint_override(:openai, "sk-proj-abc123definitelyakey")

    assert {:endpoint_override, {msg, _}} = List.keyfind(cs.errors, :endpoint_override, 0)
    assert msg =~ "http"
  end

  test "rejects bare host with no scheme" do
    assert {:error, _} = Providers.set_endpoint_override(:openai, "openai.com")
  end

  test "rejects ftp:// or other non-http schemes" do
    assert {:error, _} = Providers.set_endpoint_override(:openai, "ftp://example.com")
  end
end
