defmodule ConcilioWeb.SessionController do
  @moduledoc """
  Handles the form-post side of the login flow plus logout.

  - `POST /login` — verifies the pasted token, stamps the session, and
    redirects home.
  - `DELETE /logout` — rotates the app secret (kicks every active
    session) and clears the cookie.
  """

  use ConcilioWeb, :controller

  alias Concilio.Auth
  alias Concilio.Auth.RateLimiter
  alias Concilio.Auth.Token
  alias ConcilioWeb.Auth, as: WebAuth

  @generic_failure "Token didn't match. Try again."

  def create(conn, %{"session" => %{"token" => raw_token}}) do
    ip_key = client_ip(conn)
    submitted = String.trim(raw_token || "")

    if RateLimiter.rate_limited?(ip_key) do
      render_failure(conn, "Too many attempts. Wait a few minutes and try again.")
    else
      check_token(conn, ip_key, submitted)
    end
  end

  def delete(conn, _params) do
    conn
    |> WebAuth.log_out()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/login")
  end

  defp check_token(conn, ip_key, submitted) do
    state = Auth.get_state()
    hash = state && state.token_hash

    if Token.verify(submitted, hash) do
      :ok = RateLimiter.record_success(ip_key)

      conn
      |> WebAuth.log_in()
      |> put_flash(:info, "Welcome.")
      |> redirect(to: ~p"/")
    else
      _ = RateLimiter.record_failure(ip_key)
      render_failure(conn, @generic_failure)
    end
  end

  defp render_failure(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/login")
  end

  defp client_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end
end
