defmodule ConcilioWeb.Auth do
  @moduledoc """
  Plugs and LiveView mount hooks for the single-user session auth.

  Cookie shape: `concilio_session.token` is a Phoenix-signed binary
  containing the current `app_state.secret`. Verifying the cookie =
  reading the cookie + comparing the embedded secret against the
  current `Concilio.Auth.session_secret!/0`. Logout rotates the secret,
  which invalidates every cookie in circulation simultaneously.

  When `CONCILIO_NO_AUTH=true` is set, every request is treated as
  authenticated. Intended for development only.
  """

  use ConcilioWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  alias Concilio.Auth

  @session_key :concilio_session

  # ── Plugs ───────────────────────────────────────────────────────────

  @doc """
  Reads the session and assigns `:authenticated?` on the conn.
  Always runs; does not redirect.
  """
  def fetch_session_user(conn, _opts) do
    case maybe_consume_query_token(conn) do
      {:logged_in, conn} ->
        # Token consumed and exchanged for a session cookie; bounce
        # to the same path without the `?token=...` query so the
        # value doesn't linger in browser history. Halts the rest
        # of the pipeline; the redirect lands back through this
        # plug with the cookie already in place.
        conn
        |> redirect(to: clean_path(conn))
        |> halt()

      {:noop, conn} ->
        cond do
          no_auth_bypass?() ->
            assign(conn, :authenticated?, true)

          session_valid?(conn) ->
            assign(conn, :authenticated?, true)

          true ->
            assign(conn, :authenticated?, false)
        end
    end
  end

  # If the request carries `?token=...` (typically set by the Tauri
  # tray shell so the user never has to paste it), validate the
  # token against `app_state.token_hash` and stamp a session cookie
  # on the conn. The caller drops the query string in a redirect.
  defp maybe_consume_query_token(conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    with token when is_binary(token) <- conn.query_params["token"],
         state when not is_nil(state) <- Auth.get_state(),
         true <- Concilio.Auth.Token.verify(token, state.token_hash) do
      {:logged_in, log_in(conn)}
    else
      _ -> {:noop, conn}
    end
  end

  defp clean_path(%Plug.Conn{} = conn) do
    case Map.delete(conn.query_params, "token") do
      empty when empty == %{} -> conn.request_path
      remaining -> conn.request_path <> "?" <> URI.encode_query(remaining)
    end
  end

  @doc """
  Halts and redirects to `/login` when the conn is not authenticated.
  Pair with `fetch_session_user/2`.
  """
  def require_authenticated(conn, _opts) do
    if conn.assigns[:authenticated?] do
      conn
    else
      conn
      |> put_flash(:error, "Please sign in to continue.")
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  @doc """
  Redirects authenticated users away from `/login`. Pair with
  `fetch_session_user/2`.
  """
  def redirect_if_authenticated(conn, _opts) do
    if conn.assigns[:authenticated?] do
      conn
      |> redirect(to: ~p"/")
      |> halt()
    else
      conn
    end
  end

  # ── Session helpers (used by LoginLive / SessionController) ─────────

  @doc """
  Marks the current session as authenticated by stamping the rotating
  secret into the session cookie.
  """
  @spec log_in(Plug.Conn.t()) :: Plug.Conn.t()
  def log_in(conn) do
    conn
    |> renew_session()
    |> put_session(@session_key, Auth.session_secret!())
  end

  @doc """
  Drops the session and rotates the app secret. Every other in-flight
  cookie becomes invalid immediately.
  """
  @spec log_out(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out(conn) do
    Auth.rotate_secret!()

    conn
    |> renew_session()
    |> delete_session(@session_key)
  end

  @doc """
  True when the conn carries a current, valid session cookie.
  """
  @spec session_valid?(Plug.Conn.t()) :: boolean()
  def session_valid?(conn) do
    case get_session(conn, @session_key) do
      nil -> false
      stored when is_binary(stored) -> Plug.Crypto.secure_compare(stored, Auth.session_secret!())
    end
  end

  # ── LiveView mount hook ─────────────────────────────────────────────

  @doc """
  `on_mount` hook used by authenticated LiveViews. Reads
  `:concilio_session` out of the LiveView session map and verifies it
  against the current secret.
  """
  def on_mount(:require_authenticated, _params, session, socket) do
    cond do
      no_auth_bypass?() ->
        {:cont, Phoenix.Component.assign(socket, :authenticated?, true)}

      live_session_valid?(session) ->
        {:cont, Phoenix.Component.assign(socket, :authenticated?, true)}

      true ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
    end
  end

  defp live_session_valid?(%{"concilio_session" => stored}) when is_binary(stored) do
    Plug.Crypto.secure_compare(stored, Auth.session_secret!())
  end

  defp live_session_valid?(_), do: false

  defp no_auth_bypass? do
    System.get_env("CONCILIO_NO_AUTH") in ~w(1 true TRUE)
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
