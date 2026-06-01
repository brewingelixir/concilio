defmodule Concilio.Auth.RateLimiter do
  @moduledoc """
  In-memory ETS-backed sliding-window rate limiter for login attempts.

  Defaults: 5 attempts per 15-minute window per key (typically IP).

  This is intentionally tiny: a single-node single-user app does not
  need anything more sophisticated. Counters reset on `record_success/1`
  so a legitimate operator who fat-fingers a few times then succeeds
  can keep going.
  """

  use GenServer

  @table __MODULE__
  @default_max_attempts 5
  @default_window_ms :timer.minutes(15)
  @sweep_interval_ms :timer.minutes(1)

  # ── Public API ──────────────────────────────────────────────────────

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a failed attempt for `key`. Returns `:ok` if the caller may
  continue trying, `{:error, :rate_limited}` if the limit has been hit.
  """
  @spec record_failure(term()) :: :ok | {:error, :rate_limited}
  def record_failure(key) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_ms()

    fresh =
      case :ets.lookup(@table, key) do
        [{^key, attempts}] -> Enum.filter(attempts, &(&1 >= cutoff))
        [] -> []
      end

    new_attempts = [now | fresh]
    :ets.insert(@table, {key, new_attempts})

    if length(new_attempts) > max_attempts() do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @doc """
  Clears any failures recorded for `key`. Call after a successful login.
  """
  @spec record_success(term()) :: :ok
  def record_success(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Returns `true` if `key` is currently rate-limited.
  """
  @spec rate_limited?(term()) :: boolean()
  def rate_limited?(key) do
    cutoff = System.monotonic_time(:millisecond) - window_ms()

    case :ets.lookup(@table, key) do
      [{^key, attempts}] -> Enum.count(attempts, &(&1 >= cutoff)) >= max_attempts()
      [] -> false
    end
  end

  # ── GenServer ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - window_ms()

    # Drop expired timestamps from each row; remove rows that go empty.
    :ets.foldl(
      fn {key, attempts}, _acc ->
        case Enum.filter(attempts, &(&1 >= cutoff)) do
          [] -> :ets.delete(@table, key)
          fresh -> :ets.insert(@table, {key, fresh})
        end

        nil
      end,
      nil,
      @table
    )

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp max_attempts do
    Application.get_env(:concilio, __MODULE__, [])
    |> Keyword.get(:max_attempts, @default_max_attempts)
  end

  defp window_ms do
    Application.get_env(:concilio, __MODULE__, [])
    |> Keyword.get(:window_ms, @default_window_ms)
  end
end
