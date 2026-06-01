defmodule ConcilioWeb.LoginLive do
  @moduledoc """
  Token-paste login screen. Submission posts to
  `ConcilioWeb.SessionController.create/2` so the session cookie can be
  written from a controller (LiveView mount can't set it directly).
  """

  use ConcilioWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sign in")
     |> assign(:app_mode?, Application.get_env(:concilio, :app_mode?, false))
     |> assign(:token_path, Concilio.Auth.TokenStore.file_path())
     |> assign(:form, to_form(%{"token" => ""}, as: :session))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen grid place-items-center bg-base-200 px-4">
      <div class="card w-full max-w-md bg-base-100 shadow-md">
        <div class="card-body space-y-4">
          <h1 class="text-2xl font-semibold text-center">Concilio</h1>

          <p class="text-sm text-base-content/70 text-center">
            Paste your auth token to sign in.
          </p>

          <.form
            for={@form}
            id="login-form"
            action={~p"/login"}
            method="post"
            class="space-y-3"
          >
            <.input
              field={@form[:token]}
              type="text"
              label="Auth token"
              placeholder="Paste token…"
              class="input input-lg w-full font-mono"
              autocomplete="off"
              spellcheck="false"
              phx-mounted={JS.focus()}
              required
            />

            <button type="submit" class="btn btn-primary w-full">
              Unlock
            </button>
          </.form>

          <p class="text-xs text-base-content/50 text-center">
            <%= if @app_mode? do %>
              Concilio opens automatically with your token. Lost access? Use the tray menu &rarr; Reset Auth Token.
            <% else %>
              The token was printed to the server console on first boot and saved to <code class="font-mono break-all">{@token_path}</code>. Lost it? Run <code class="font-mono">mix concilio.reset_token</code>.
            <% end %>
          </p>
        </div>
      </div>
    </div>
    """
  end
end
