defmodule Concilio.Providers.Setting do
  @moduledoc """
  Per-provider configuration row. One row per provider atom; credentials
  are stored encrypted via `Concilio.Crypto`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @providers [:openai, :anthropic, :openrouter, :ollama, :gemini]

  @type provider :: :openai | :anthropic | :openrouter | :ollama | :gemini

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          provider: provider() | nil,
          enabled: boolean(),
          encrypted_credentials: binary() | nil,
          endpoint_override: String.t() | nil,
          options_json: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "provider_settings" do
    field :provider, Ecto.Enum, values: @providers
    field :enabled, :boolean, default: false
    field :encrypted_credentials, :binary
    field :endpoint_override, :string
    field :options_json, :map, default: %{}

    timestamps()
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :provider,
      :enabled,
      :encrypted_credentials,
      :endpoint_override,
      :options_json
    ])
    |> validate_required([:provider])
    |> validate_inclusion(:provider, @providers)
    |> validate_endpoint_override()
    |> unique_constraint(:provider)
  end

  defp validate_endpoint_override(changeset) do
    case get_field(changeset, :endpoint_override) do
      nil ->
        changeset

      "" ->
        changeset

      value when is_binary(value) ->
        case URI.parse(value) do
          %URI{scheme: scheme, host: host}
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            changeset

          _ ->
            add_error(
              changeset,
              :endpoint_override,
              "must be a full http(s) URL (e.g. https://api.example.com/v1)"
            )
        end
    end
  end

  @spec providers() :: [provider()]
  def providers, do: @providers
end
