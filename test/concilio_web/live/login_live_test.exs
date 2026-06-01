defmodule ConcilioWeb.LoginLiveTest do
  use ConcilioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Concilio.Auth
  alias Concilio.Auth.RateLimiter
  alias Concilio.Auth.Token

  setup do
    # Clear any rate-limiter state left over from sibling tests.
    :ok = RateLimiter.record_success("127.0.0.1")

    # Seed a known token for /login flow tests.
    token = Token.generate()
    {:ok, _} = Auth.put_token_hash(Token.hash(token))
    _ = Auth.rotate_secret!()

    %{token: token}
  end

  test "renders the login form", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/login")
    assert html =~ "Concilio"
    assert html =~ "Auth token"
  end

  test "POST /login with the right token signs the user in", %{conn: conn, token: token} do
    conn = post(conn, ~p"/login", %{"session" => %{"token" => token}})
    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :concilio_session) == Auth.session_secret!()
  end

  test "POST /login with the wrong token redirects back with an error", %{conn: conn} do
    conn = post(conn, ~p"/login", %{"session" => %{"token" => "nope"}})
    assert redirected_to(conn) == ~p"/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't match"
  end

  test "after enough failures the IP is rate-limited", %{conn: conn} do
    Enum.each(1..5, fn _ ->
      _ = post(conn, ~p"/login", %{"session" => %{"token" => "nope"}})
    end)

    conn = post(conn, ~p"/login", %{"session" => %{"token" => "nope"}})
    assert redirected_to(conn) == ~p"/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many"
  end

  test "DELETE /logout rotates the secret and clears the session", %{conn: conn, token: token} do
    # Sign in.
    conn = post(conn, ~p"/login", %{"session" => %{"token" => token}})
    secret_before = Auth.session_secret!()
    assert get_session(conn, :concilio_session) == secret_before

    # Sign out — secret rotates.
    conn = delete(recycle(conn), ~p"/logout")
    assert redirected_to(conn) == ~p"/login"

    refute Auth.session_secret!() == secret_before
  end
end
