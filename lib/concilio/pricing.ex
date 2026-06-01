defmodule Concilio.Pricing do
  @moduledoc """
  Static price table for popular LLM models. Prices are stored as
  *millicents per million tokens* (i.e. tenths of a cent × 100) so cost
  math stays in integers, but the public API takes plain dollars-per-M
  and exposes integer cents for callers.

  This table will go stale. Edit it (or replace it with a database-backed
  table) when prices move. Unknown model lookups return `nil`, in which
  case the caller should treat cost as unknown rather than zero.

  Pricing as of mid-2025; sourced from each provider's public pricing
  page. Only frontier + commonly-used models are listed — if a council
  uses a model not in this table the run will simply lack a cost figure.
  """

  # USD per million tokens, {input, output}
  @prices %{
    # OpenAI
    "gpt-4o" => {2.50, 10.00},
    "gpt-4o-mini" => {0.15, 0.60},
    "gpt-4.1" => {2.00, 8.00},
    "gpt-4.1-mini" => {0.40, 1.60},
    "gpt-4.1-nano" => {0.10, 0.40},
    "o1" => {15.00, 60.00},
    "o1-mini" => {3.00, 12.00},
    "o3-mini" => {1.10, 4.40},
    "o3" => {2.00, 8.00},
    "o4-mini" => {1.10, 4.40},
    "gpt-5" => {10.00, 30.00},
    "gpt-5-mini" => {0.50, 2.00},
    # Anthropic
    "claude-opus-4-5" => {15.00, 75.00},
    "claude-opus-4-7" => {15.00, 75.00},
    "claude-sonnet-4-5" => {3.00, 15.00},
    "claude-sonnet-4-6" => {3.00, 15.00},
    "claude-haiku-4-5" => {1.00, 5.00},
    "claude-haiku-4-5-20251001" => {1.00, 5.00},
    "claude-3-5-sonnet" => {3.00, 15.00},
    "claude-3-5-haiku" => {0.80, 4.00},
    "claude-3-opus" => {15.00, 75.00},
    # Google
    "gemini-2.5-pro" => {1.25, 5.00},
    "gemini-2.5-flash" => {0.30, 2.50},
    "gemini-2.5-flash-lite" => {0.10, 0.40},
    "gemini-2.0-flash" => {0.10, 0.40}
  }

  @doc """
  Cost in *cents* (rounded up to nearest cent) for the given model and
  token usage. Returns `nil` when the model is not in the price table.
  """
  @spec cost_cents(String.t() | nil, non_neg_integer(), non_neg_integer()) ::
          non_neg_integer() | nil
  def cost_cents(nil, _, _), do: nil

  def cost_cents(model, input_tokens, output_tokens)
      when is_binary(model) and is_integer(input_tokens) and is_integer(output_tokens) do
    case lookup(model) do
      nil ->
        nil

      {in_per_m, out_per_m} ->
        usd = input_tokens * in_per_m / 1_000_000 + output_tokens * out_per_m / 1_000_000
        # Round up to the cent so we never under-report.
        ceil(usd * 100)
    end
  end

  def cost_cents(_, _, _), do: nil

  @doc """
  Sum the cost of every member response in a `%CouncilEx.Result{}`. Returns
  `nil` when *no* response had a known model — otherwise sums what we can,
  treating unknowns as 0 (the metric is "best-effort cost so far").
  """
  @spec result_cost_cents(map()) :: non_neg_integer() | nil
  def result_cost_cents(result) do
    rounds = Map.get(result, :rounds) || []

    {sum, known?} =
      Enum.reduce(rounds, {0, false}, fn round, acc ->
        member_results = Map.get(round, :member_results) || []

        Enum.reduce(member_results, acc, fn entry, {acc_sum, acc_known} ->
          {model, input_tokens, output_tokens} = extract(entry)

          case cost_cents(model, input_tokens, output_tokens) do
            nil -> {acc_sum, acc_known}
            cents -> {acc_sum + cents, true}
          end
        end)
      end)

    if known?, do: sum, else: nil
  end

  defp extract({_id, %{response: %{model: m, usage: %{input_tokens: i, output_tokens: o}}}}),
    do: {m, i, o}

  defp extract(
         {_id, %{response: %{model: m, usage: %{"input_tokens" => i, "output_tokens" => o}}}}
       ),
       do: {m, i, o}

  defp extract(_), do: {nil, 0, 0}

  defp lookup(model) do
    Map.get(@prices, model) ||
      Enum.find_value(@prices, fn {prefix, price} ->
        if String.starts_with?(model, prefix), do: price
      end)
  end
end
