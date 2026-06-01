defmodule Concilio.Providers do
  @moduledoc """
  Provider context: configuration rows + curated model catalog +
  per-row test results. Encrypted-at-rest credentials use
  `Concilio.Crypto`.
  """

  import Ecto.Query, warn: false

  alias Concilio.Crypto
  alias Concilio.Providers.{Catalog, Model, Runtime, Setting}
  alias Concilio.Repo

  # ── Settings ────────────────────────────────────────────────────────

  @doc """
  True iff at least one provider is enabled with credentials AND has
  at least one model in its working set. Used as the onboarding gate
  for chat + run-now.
  """
  @spec any_configured?() :: boolean()
  def any_configured? do
    enabled =
      Repo.all(
        from s in Setting,
          where: s.enabled == true,
          where: not is_nil(s.encrypted_credentials) or s.provider == :ollama
      )

    Enum.any?(enabled, fn s ->
      Repo.exists?(
        from m in Model,
          where: m.provider == ^s.provider and m.in_working_set == true,
          where: is_nil(m.deprecated_at)
      )
    end)
  end

  @doc """
  Inspect a list of `{provider_atom, model_id}` pairs and return a list of
  pairs that are NOT yet runnable (provider disabled / no key / model not in
  working set / model deprecated). Empty list = ready to run.
  """
  @spec missing_requirements([{atom(), String.t()}]) :: [{atom(), String.t()}]
  def missing_requirements(requirements) when is_list(requirements) do
    enabled_providers =
      Repo.all(
        from s in Setting,
          where: s.enabled == true,
          where: not is_nil(s.encrypted_credentials) or s.provider == :ollama,
          select: s.provider
      )
      |> MapSet.new()

    Enum.reject(requirements, fn {provider, model_id} ->
      MapSet.member?(enabled_providers, provider) and
        Repo.exists?(
          from m in Model,
            where: m.provider == ^provider and m.model_id == ^model_id,
            where: m.in_working_set == true,
            where: is_nil(m.deprecated_at)
        )
    end)
  end

  @doc """
  Returns the row for a provider, inserting an empty placeholder if
  none exists yet. Idempotent.
  """
  @spec get_or_create_setting!(atom()) :: Setting.t()
  def get_or_create_setting!(provider) when is_atom(provider) do
    case Repo.get_by(Setting, provider: provider) do
      nil ->
        %Setting{}
        |> Setting.changeset(%{provider: provider})
        |> Repo.insert!()

      existing ->
        existing
    end
  end

  @doc """
  All provider settings rows in a stable order.
  """
  @spec list_settings() :: [Setting.t()]
  def list_settings do
    Repo.all(from s in Setting, order_by: [asc: s.provider])
  end

  @doc """
  Toggle a provider's `enabled` flag.
  """
  @spec set_enabled(atom(), boolean()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def set_enabled(provider, enabled?) do
    provider
    |> get_or_create_setting!()
    |> Setting.changeset(%{enabled: enabled?})
    |> Repo.update()
    |> tap_runtime_refresh()
  end

  @doc """
  Removes a provider entirely: drops the `provider_settings` row plus
  every `provider_models` row for that provider. Used by the "X" button
  in the Providers tab to take a provider out of the user's list (with
  an inline confirmation when the provider has tested-OK models).

  Idempotent — succeeds even if the row is already gone.
  """
  @spec remove(atom()) :: :ok
  def remove(provider) when is_atom(provider) do
    Repo.transaction(fn ->
      Repo.delete_all(from m in Model, where: m.provider == ^provider)
      Repo.delete_all(from s in Setting, where: s.provider == ^provider)
    end)

    tap_runtime_refresh({:ok, nil})
    :ok
  end

  @doc """
  True when `provider` has stored credentials (or is :ollama, which
  needs none) AND at least one of its `Model` rows reports
  `last_test_status: :ok`. Use this — not `setting.enabled` — when
  rendering UI status, since `enabled` is set the moment a provider
  is added but the actual ability to call the provider depends on a
  working ping.
  """
  @spec working?(atom()) :: boolean()
  def working?(provider) when is_atom(provider) do
    setting = Repo.get_by(Setting, provider: provider)
    working?(setting, list_provider_models(provider))
  end

  @spec working?(Setting.t() | nil, [Model.t()]) :: boolean()
  def working?(nil, _models), do: false

  def working?(%Setting{} = setting, models) when is_list(models) do
    key_present? = setting.provider == :ollama or not is_nil(setting.encrypted_credentials)
    has_ok_test? = Enum.any?(models, &(&1.last_test_status == :ok))

    key_present? and has_ok_test?
  end

  defp list_provider_models(provider) do
    Repo.all(
      from m in Model,
        where: m.provider == ^provider,
        where: is_nil(m.deprecated_at)
    )
  end

  @doc """
  Replace a provider's API key. Encrypts at rest. An empty string clears
  the credential.
  """
  @spec set_api_key(atom(), String.t() | nil) :: {:ok, Setting.t()} | {:error, term()}
  def set_api_key(provider, api_key) do
    encrypted =
      case api_key do
        nil -> nil
        "" -> nil
        plain when is_binary(plain) -> Crypto.encrypt(plain)
      end

    provider
    |> get_or_create_setting!()
    |> Setting.changeset(%{encrypted_credentials: encrypted})
    |> Repo.update()
    |> tap_runtime_refresh()
  end

  @doc """
  Decrypt the stored API key, if any.
  """
  @spec get_api_key(atom()) :: {:ok, String.t()} | :missing | :error
  def get_api_key(provider) do
    case Repo.get_by(Setting, provider: provider) do
      %Setting{encrypted_credentials: nil} -> :missing
      %Setting{encrypted_credentials: ct} -> Crypto.decrypt(ct)
      nil -> :missing
    end
  end

  @doc """
  Set/clear the endpoint override for a provider.
  """
  @spec set_endpoint_override(atom(), String.t() | nil) ::
          {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def set_endpoint_override(provider, endpoint) do
    provider
    |> get_or_create_setting!()
    |> Setting.changeset(%{endpoint_override: endpoint})
    |> Repo.update()
    |> tap_runtime_refresh()
  end

  defp tap_runtime_refresh({:ok, _} = ok) do
    _ = Runtime.refresh!()
    ok
  end

  defp tap_runtime_refresh(other), do: other

  # ── Models ──────────────────────────────────────────────────────────

  @doc """
  All models for a provider, ordered by working-set first then model_id.
  """
  @spec list_models(atom()) :: [Model.t()]
  def list_models(provider) when is_atom(provider) do
    Repo.all(
      from m in Model,
        where: m.provider == ^provider,
        where: is_nil(m.deprecated_at),
        order_by: [desc: m.in_working_set, asc: m.model_id]
    )
  end

  @doc """
  Working-set models across every provider.
  """
  @spec list_working_set_models() :: [Model.t()]
  def list_working_set_models do
    Repo.all(
      from m in Model,
        where: m.in_working_set == true,
        where: is_nil(m.deprecated_at),
        order_by: [asc: m.provider, asc: m.model_id]
    )
  end

  @doc """
  Toggle a model's working-set membership.
  """
  @spec toggle_in_working_set(Model.t()) :: {:ok, Model.t()} | {:error, Ecto.Changeset.t()}
  def toggle_in_working_set(%Model{} = model) do
    model
    |> Model.changeset(%{in_working_set: not model.in_working_set})
    |> Repo.update()
  end

  @doc """
  Ensure each `model_id` exists for `provider` and is in the working
  set (and not deprecated). Inserts missing rows with `source:
  :user_added`; flips existing rows on. Returns the resolved Model
  rows. Used by the Settings UI when a provider is enabled so every
  model referenced by a council template gets pre-selected.
  """
  @spec ensure_models_in_working_set(atom(), [String.t()]) :: [Model.t()]
  def ensure_models_in_working_set(provider, model_ids)
      when is_atom(provider) and is_list(model_ids) do
    Enum.map(model_ids, fn model_id ->
      case Repo.get_by(Model, provider: provider, model_id: model_id) do
        nil ->
          {:ok, m} = add_user_model(provider, model_id)
          m

        %Model{in_working_set: true, deprecated_at: nil} = existing ->
          existing

        %Model{} = existing ->
          {:ok, m} =
            existing
            |> Model.changeset(%{in_working_set: true, deprecated_at: nil})
            |> Repo.update()

          m
      end
    end)
  end

  @doc """
  Add a user-defined custom model. Defaults to `in_working_set: true`.
  """
  @spec add_user_model(atom(), String.t(), keyword()) :: {:ok, Model.t()} | {:error, term()}
  def add_user_model(provider, model_id, opts \\ [])
      when is_atom(provider) and is_binary(model_id) do
    %Model{}
    |> Model.changeset(%{
      provider: provider,
      model_id: model_id,
      in_working_set: Keyword.get(opts, :in_working_set, true),
      source: :user_added,
      metadata_json: Keyword.get(opts, :metadata, %{})
    })
    |> Repo.insert(
      on_conflict: {:replace, [:in_working_set, :metadata_json]},
      conflict_target: [:provider, :model_id]
    )
  end

  @doc """
  Record the result of a one-shot test ping.
  """
  @spec record_test_result(Model.t(), %{required(:status) => atom()} | map()) ::
          {:ok, Model.t()} | {:error, Ecto.Changeset.t()}
  def record_test_result(%Model{} = model, %{} = result) do
    model
    |> Model.changeset(%{
      last_test_at: DateTime.utc_now(),
      last_test_status: Map.get(result, :status),
      last_test_latency_ms: Map.get(result, :latency_ms),
      last_test_error: Map.get(result, :error)
    })
    |> Repo.update()
  end

  # ── Bundled-catalog reconciliation ──────────────────────────────────

  @doc """
  Reconciles the bundled catalog into the DB. New `bundled` entries are
  inserted; bundled rows that no longer appear in the source list get
  `deprecated_at` stamped (never deleted). User-added rows are
  untouched. Returns the number of newly inserted rows.
  """
  @spec sync_bundled_catalog!() :: %{inserted: non_neg_integer(), deprecated: non_neg_integer()}
  def sync_bundled_catalog! do
    Enum.reduce(Catalog.providers(), %{inserted: 0, deprecated: 0}, fn provider, acc ->
      desired = Catalog.for_provider(provider)
      desired_ids = MapSet.new(desired, & &1.model_id)

      existing_bundled =
        Repo.all(
          from m in Model,
            where: m.provider == ^provider,
            where: m.source == :bundled
        )

      existing_ids = MapSet.new(existing_bundled, & &1.model_id)

      to_insert = Enum.reject(desired, fn entry -> entry.model_id in existing_ids end)

      inserted =
        Enum.count(to_insert, fn entry ->
          {:ok, _} =
            %Model{}
            |> Model.changeset(%{
              provider: provider,
              model_id: entry.model_id,
              source: :bundled,
              metadata_json: %{label: entry.label}
            })
            |> Repo.insert(
              on_conflict: {:replace, [:source, :metadata_json, :deprecated_at]},
              conflict_target: [:provider, :model_id]
            )

          true
        end)

      to_deprecate =
        Enum.filter(existing_bundled, fn m ->
          is_nil(m.deprecated_at) and m.model_id not in desired_ids
        end)

      deprecated =
        Enum.count(to_deprecate, fn m ->
          {:ok, _} =
            m
            |> Model.changeset(%{deprecated_at: DateTime.utc_now()})
            |> Repo.update()

          true
        end)

      %{inserted: acc.inserted + inserted, deprecated: acc.deprecated + deprecated}
    end)
  end
end
