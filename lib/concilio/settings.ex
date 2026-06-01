defmodule Concilio.Settings do
  @moduledoc """
  File-backed user settings under `~/.concilio/settings.toml`.

  Single-user, local-only — encrypted material (provider API keys, auth
  token hash) stays in DB rows, not here. This file holds only plaintext
  preferences that the user is welcome to edit by hand.

  ## Lifecycle

  Loaded once on app boot, cached in this GenServer. Reads go through
  `get_defaults/0` (single message hop, low rate). Writes serialize
  through `put_defaults/1` and atomically rewrite the file.

  ## Snapshot rule

  Per kickoff: in-flight runs use the values they captured at start. New
  runs read fresh from this module via `RunStarter`. Don't read settings
  from a long-running process loop.

  ## Override path

      config :concilio, Concilio.Settings, path: "/tmp/test-settings.toml"

  Set in `config/test.exs` per-suite. Production uses
  `~/.concilio/settings.toml`.
  """

  use GenServer

  require Logger

  @schema_version 1
  @failure_modes ~w(continue fail_fast)a
  @min_timeout_ms 1_000
  @max_timeout_ms 600_000

  defmodule Defaults do
    @moduledoc """
    Defaults applied to new councils/conversations.

    `failure_mode` is `:continue | :fail_fast` per `CouncilEx.Runner`.
    """
    defstruct council_template_slug: nil,
              chairman_model: nil,
              member_timeout_ms: 30_000,
              failure_mode: :continue

    @type t :: %__MODULE__{
            council_template_slug: String.t() | nil,
            chairman_model: String.t() | nil,
            member_timeout_ms: pos_integer(),
            failure_mode: :continue | :fail_fast
          }
  end

  defmodule Display do
    @moduledoc """
    UI display preferences. Theme acts as the initial default before
    `localStorage["phx:theme"]` takes over client-side; explicit user
    flips on the navbar still write to localStorage and win locally.
    """
    defstruct theme: "system", stream_tokens: true

    @type t :: %__MODULE__{
            theme: String.t(),
            stream_tokens: boolean()
          }
  end

  @themes ~w(system light dark)

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Current defaults. Always returns a `%Defaults{}`.

  When the GenServer is not running (e.g. before a dev-server restart
  has picked up the new supervision child, or in test envs that opt
  out of the bootstrapper), falls back to a fresh disk read from the
  configured path. This keeps reads resilient at the cost of skipping
  the in-memory cache.
  """
  @spec get_defaults(GenServer.server()) :: Defaults.t()
  def get_defaults(server \\ __MODULE__) do
    case alive_pid(server) do
      nil -> load_defaults_from_disk(default_path())
      pid -> GenServer.call(pid, :get_defaults)
    end
  end

  @doc """
  Replace the defaults section. `attrs` accepts string or atom keys;
  unknown keys are ignored. Returns `{:ok, defaults}` on success or
  `{:error, [{field, message}]}` on validation failure.

  Requires the GenServer to be running — writes have to serialize
  through one process. Returns `{:error, :settings_not_started}` if
  the server is missing.
  """
  @spec put_defaults(map(), GenServer.server()) ::
          {:ok, Defaults.t()}
          | {:error, [{atom(), String.t()}]}
          | {:error, :settings_not_started}
  def put_defaults(attrs, server \\ __MODULE__) when is_map(attrs) do
    case alive_pid(server) do
      nil -> {:error, :settings_not_started}
      pid -> GenServer.call(pid, {:put_defaults, attrs})
    end
  end

  defp alive_pid(name) when is_atom(name), do: Process.whereis(name)
  defp alive_pid(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid, else: nil)
  defp alive_pid(other), do: other

  @doc "Current display preferences. Falls back to disk if no GenServer."
  @spec get_display(GenServer.server()) :: Display.t()
  def get_display(server \\ __MODULE__) do
    case alive_pid(server) do
      nil -> load_display_from_disk(default_path())
      pid -> GenServer.call(pid, :get_display)
    end
  end

  @doc "Replace the display section."
  @spec put_display(map(), GenServer.server()) ::
          {:ok, Display.t()}
          | {:error, [{atom(), String.t()}]}
          | {:error, :settings_not_started}
  def put_display(attrs, server \\ __MODULE__) when is_map(attrs) do
    case alive_pid(server) do
      nil -> {:error, :settings_not_started}
      pid -> GenServer.call(pid, {:put_display, attrs})
    end
  end

  @doc "Available theme values."
  def themes, do: @themes

  @doc "Resolved path for the running server (or app env if no server given)."
  def path(server \\ __MODULE__)

  def path(__MODULE__) do
    case Process.whereis(__MODULE__) do
      nil -> default_path()
      pid -> GenServer.call(pid, :path)
    end
  end

  def path(server) do
    case alive_pid(server) do
      nil -> default_path()
      pid -> GenServer.call(pid, :path)
    end
  end

  defp default_path do
    Application.get_env(:concilio, __MODULE__, [])
    |> Keyword.get(:path)
    |> case do
      nil -> Path.expand("~/.concilio/settings.toml")
      p -> p
    end
  end

  @doc "Failure modes accepted by the form."
  def failure_modes, do: @failure_modes

  # ── GenServer ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path) || default_path()

    {:ok,
     %{
       path: path,
       defaults: load_defaults_from_disk(path),
       display: load_display_from_disk(path)
     }}
  end

  @impl true
  def handle_call(:get_defaults, _from, state) do
    state = ensure_defaults(state)
    {:reply, state.defaults, state}
  end

  def handle_call(:get_display, _from, state) do
    state = ensure_display(state)
    {:reply, state.display, state}
  end

  def handle_call(:path, _from, state) do
    {:reply, state.path, state}
  end

  def handle_call({:put_defaults, attrs}, _from, state) do
    state = state |> ensure_defaults() |> ensure_display()

    case validate_defaults(attrs, state.defaults) do
      {:ok, defaults} ->
        new_state = %{state | defaults: defaults}

        case write_atomic(new_state) do
          :ok ->
            {:reply, {:ok, defaults}, new_state}

          {:error, reason} ->
            Logger.error("Concilio.Settings write failed: #{inspect(reason)}")
            {:reply, {:error, [{:_, "could not write settings file: #{inspect(reason)}"}]}, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:put_display, attrs}, _from, state) do
    state = state |> ensure_defaults() |> ensure_display()

    case validate_display(attrs, state.display) do
      {:ok, display} ->
        new_state = %{state | display: display}

        case write_atomic(new_state) do
          :ok ->
            {:reply, {:ok, display}, new_state}

          {:error, reason} ->
            Logger.error("Concilio.Settings write failed: #{inspect(reason)}")
            {:reply, {:error, [{:_, "could not write settings file: #{inspect(reason)}"}]}, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # Self-heal across dev hot-reload: a GenServer started with an older
  # version of init/1 won't have new keys in state. Lazy-load missing
  # sections from disk on first access.
  defp ensure_defaults(state) do
    case Map.fetch(state, :defaults) do
      {:ok, _} -> state
      :error -> Map.put(state, :defaults, load_defaults_from_disk(state.path))
    end
  end

  defp ensure_display(state) do
    case Map.fetch(state, :display) do
      {:ok, _} -> state
      :error -> Map.put(state, :display, load_display_from_disk(state.path))
    end
  end

  # ── Disk I/O ────────────────────────────────────────────────────────

  defp load_defaults_from_disk(path) do
    case parse_file(path) do
      {:ok, parsed} -> coerce_defaults(Map.get(parsed, "defaults", %{}))
      :empty -> %Defaults{}
    end
  end

  defp load_display_from_disk(path) do
    case parse_file(path) do
      {:ok, parsed} -> coerce_display(Map.get(parsed, "display", %{}))
      :empty -> %Display{}
    end
  end

  defp parse_file(path) do
    case File.read(path) do
      {:ok, body} ->
        case Toml.decode(body) do
          {:ok, parsed} ->
            {:ok, parsed}

          {:error, reason} ->
            Logger.warning(
              "Concilio.Settings: could not parse #{path} (#{inspect(reason)}); using defaults"
            )

            :empty
        end

      {:error, :enoent} ->
        :empty

      {:error, reason} ->
        Logger.warning(
          "Concilio.Settings: could not read #{path} (#{inspect(reason)}); using defaults"
        )

        :empty
    end
  end

  defp coerce_defaults(map) when is_map(map) do
    %Defaults{
      council_template_slug: blank_to_nil(map["council_template_slug"]),
      chairman_model: blank_to_nil(map["chairman_model"]),
      member_timeout_ms: as_int(map["member_timeout_ms"], 30_000),
      failure_mode: as_failure_mode(map["failure_mode"], :continue)
    }
  end

  defp coerce_display(map) when is_map(map) do
    %Display{
      theme: as_theme(map["theme"], "system"),
      stream_tokens: as_bool(map["stream_tokens"], true)
    }
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s
  defp blank_to_nil(_), do: nil

  defp as_int(n, _) when is_integer(n) and n > 0, do: n
  defp as_int(_, default), do: default

  defp as_failure_mode(s, _) when s in ["continue", "fail_fast"], do: String.to_atom(s)
  defp as_failure_mode(_, default), do: default

  defp as_theme(s, _) when s in ["system", "light", "dark"], do: s
  defp as_theme(_, default), do: default

  defp as_bool(b, _) when is_boolean(b), do: b
  defp as_bool(_, default), do: default

  defp write_atomic(state) do
    path = state.path
    dir = Path.dirname(path)
    tmp = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, encode(state)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _} = err ->
        _ = File.rm(tmp)
        err
    end
  end

  defp encode(state) do
    %Defaults{} = d = state.defaults
    %Display{} = disp = state.display

    [
      "# Concilio settings — edit by hand or via /settings.\n",
      "schema_version = #{@schema_version}\n",
      "\n",
      "[defaults]\n",
      kv("council_template_slug", d.council_template_slug),
      kv("chairman_model", d.chairman_model),
      "member_timeout_ms = #{d.member_timeout_ms}\n",
      "failure_mode = #{toml_string(Atom.to_string(d.failure_mode))}\n",
      "\n",
      "[display]\n",
      "theme = #{toml_string(disp.theme)}\n",
      "stream_tokens = #{disp.stream_tokens}\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp kv(_key, nil), do: ""
  defp kv(key, value) when is_binary(value), do: "#{key} = #{toml_string(value)}\n"

  # TOML basic-string encoding: backslash + double-quote escaped, control
  # chars rendered with explicit escapes. Sufficient for slug + model id
  # values, which are alphanumeric + `- _ . / : @`.
  defp toml_string(s) when is_binary(s) do
    inner =
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"" <> inner <> "\""
  end

  # ── Validation ──────────────────────────────────────────────────────

  defp validate_defaults(attrs, %Defaults{} = current) do
    attrs = normalize_keys(attrs)

    with {:ok, slug} <- validate_optional_string(attrs, "council_template_slug"),
         {:ok, chairman} <- validate_optional_string(attrs, "chairman_model"),
         {:ok, timeout} <- validate_timeout(attrs, current.member_timeout_ms),
         {:ok, mode} <- validate_failure_mode(attrs, current.failure_mode) do
      {:ok,
       %Defaults{
         council_template_slug: slug,
         chairman_model: chairman,
         member_timeout_ms: timeout,
         failure_mode: mode
       }}
    end
  end

  defp validate_display(attrs, %Display{} = current) do
    attrs = normalize_keys(attrs)

    with {:ok, theme} <- validate_theme(attrs, current.theme),
         {:ok, stream} <- validate_bool(attrs, "stream_tokens", current.stream_tokens) do
      {:ok, %Display{theme: theme, stream_tokens: stream}}
    end
  end

  defp validate_theme(attrs, fallback) do
    case attrs["theme"] do
      nil -> {:ok, fallback}
      v when v in ["system", "light", "dark"] -> {:ok, v}
      _ -> {:error, [{:theme, "must be one of: system, light, dark"}]}
    end
  end

  defp validate_bool(attrs, key, fallback) do
    case attrs[key] do
      nil -> {:ok, fallback}
      true -> {:ok, true}
      false -> {:ok, false}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      "on" -> {:ok, true}
      "off" -> {:ok, false}
      _ -> {:error, [{String.to_atom(key), "must be a boolean"}]}
    end
  end

  defp normalize_keys(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp validate_optional_string(attrs, key) do
    case attrs[key] do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      v when is_binary(v) -> {:ok, String.trim(v)}
      _ -> {:error, [{String.to_atom(key), "must be a string"}]}
    end
  end

  defp validate_timeout(attrs, fallback) do
    raw = attrs["member_timeout_ms"]

    parsed =
      cond do
        is_integer(raw) -> raw
        is_binary(raw) and raw != "" -> Integer.parse(raw) |> elem_or(:error)
        is_nil(raw) -> fallback
        true -> :error
      end

    case parsed do
      n when is_integer(n) and n >= @min_timeout_ms and n <= @max_timeout_ms ->
        {:ok, n}

      _ ->
        {:error,
         [
           {:member_timeout_ms,
            "must be an integer between #{@min_timeout_ms} and #{@max_timeout_ms} ms"}
         ]}
    end
  end

  defp elem_or({n, ""}, _), do: n
  defp elem_or(_, fallback), do: fallback

  defp validate_failure_mode(attrs, fallback) do
    case attrs["failure_mode"] do
      nil ->
        {:ok, fallback}

      v when v in ["continue", "fail_fast"] ->
        {:ok, String.to_atom(v)}

      v when v in [:continue, :fail_fast] ->
        {:ok, v}

      _ ->
        {:error, [{:failure_mode, "must be one of: continue, fail_fast"}]}
    end
  end
end
