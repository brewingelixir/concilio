defmodule ConcilioWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ConcilioWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :max_w, :string,
    default: "max-w-7xl",
    doc:
      "Tailwind max-width class for the main container. Pages with form-only content can pass `max-w-3xl`; chat/run/timeline pages get the default wide canvas."

  attr :show_nav, :boolean,
    default: true,
    doc: "When false, the top navbar is hidden (useful on `/login`)."

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%= if @show_nav do %>
      <header class="navbar bg-base-100 border-b border-base-200 px-4 sm:px-6 lg:px-8">
        <div class="navbar-start">
          <.link navigate={~p"/"} class="flex w-fit items-center gap-2 text-primary">
            <.logo class="size-7" />
            <span class="text-base font-semibold text-base-content">Concilio</span>
          </.link>
        </div>

        <div class="navbar-center hidden md:flex">
          <nav class="flex items-center gap-1 text-sm">
            <.link navigate={~p"/"} class="btn btn-ghost btn-sm">Chat</.link>
            <.link navigate={~p"/councils"} class="btn btn-ghost btn-sm">Councils</.link>
            <.link navigate={~p"/runs"} class="btn btn-ghost btn-sm">Runs</.link>
            <.link navigate={~p"/settings"} class="btn btn-ghost btn-sm">Settings</.link>
          </nav>
        </div>

        <div class="navbar-end">
          <div class="dropdown dropdown-end">
            <div
              tabindex="0"
              role="button"
              aria-label="Open account menu"
              class="btn btn-ghost btn-sm btn-circle"
            >
              <.icon name="hero-bars-3" class="size-5" />
            </div>
            <ul
              tabindex="0"
              class="dropdown-content menu menu-sm bg-base-100 rounded-box z-[1] mt-2 w-60 p-2 shadow-lg border border-base-200"
            >
              <li class="menu-title">
                <span>Theme</span>
              </li>
              <li class="px-2 py-1 list-none">
                <.theme_toggle />
              </li>
              <li><hr class="my-1 border-base-200" /></li>
              <li>
                <.link href={~p"/logout"} method="delete" class="text-error">
                  <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Sign out
                </.link>
              </li>
            </ul>
          </div>
        </div>
      </header>
    <% end %>

    <main class="px-4 py-6 sm:px-6 lg:px-8">
      <div class={["mx-auto space-y-4", @max_w]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} dismiss_after={4000} />
      <.flash kind={:error} flash={@flash} dismiss_after={6000} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Concilio mark — center node (chairman) ringed by three council nodes.
  Inline SVG so `currentColor` inherits from the surrounding text color.
  """
  attr :class, :string, default: "size-7"

  def logo(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 32 32"
      fill="none"
      class={@class}
      aria-hidden="true"
    >
      <line
        x1="16"
        y1="16"
        x2="16"
        y2="5"
        stroke="currentColor"
        stroke-width="1.25"
        stroke-linecap="round"
        opacity="0.45"
      />
      <line
        x1="16"
        y1="16"
        x2="6.47"
        y2="21.5"
        stroke="currentColor"
        stroke-width="1.25"
        stroke-linecap="round"
        opacity="0.45"
      />
      <line
        x1="16"
        y1="16"
        x2="25.53"
        y2="21.5"
        stroke="currentColor"
        stroke-width="1.25"
        stroke-linecap="round"
        opacity="0.45"
      />
      <circle cx="16" cy="5" r="2.5" fill="currentColor" />
      <circle cx="6.47" cy="21.5" r="2.5" fill="currentColor" />
      <circle cx="25.53" cy="21.5" r="2.5" fill="currentColor" />
      <circle cx="16" cy="16" r="3.75" fill="currentColor" />
    </svg>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
