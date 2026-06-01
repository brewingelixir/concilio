defmodule Concilio.Auth.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Concilio.Auth.RateLimiter

  setup do
    # Use a unique key per test so we don't collide on shared ETS state.
    %{key: "rl-test-#{System.unique_integer([:positive])}"}
  end

  test "allows attempts up to the limit then trips", %{key: key} do
    # Default: 5 attempts. The 6th should report rate-limited.
    for _ <- 1..5 do
      assert :ok = RateLimiter.record_failure(key)
    end

    assert {:error, :rate_limited} = RateLimiter.record_failure(key)
    assert RateLimiter.rate_limited?(key)
  end

  test "record_success/1 clears the counter", %{key: key} do
    for _ <- 1..3, do: RateLimiter.record_failure(key)
    assert :ok = RateLimiter.record_success(key)

    refute RateLimiter.rate_limited?(key)
  end

  test "rate_limited?/1 is false for an unseen key" do
    refute RateLimiter.rate_limited?("never-seen-#{System.unique_integer([:positive])}")
  end
end
