defmodule KeeplixWeb.Layouts do
  @moduledoc """
  Layouts fuer keeplix: hell, kontrastreich, gut lesbar.
  """
  use KeeplixWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :any, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="bg-slate-900 text-white shadow">
      <div class="mx-auto max-w-6xl px-4 py-3 flex flex-wrap items-center gap-x-6 gap-y-2">
        <a href="/app" class="flex items-center gap-2 font-bold text-lg tracking-tight text-white">
          <span class="inline-flex h-8 w-8 items-center justify-center rounded-lg bg-white font-black text-slate-900">K</span>
          keeplix
        </a>
        <nav class="flex flex-wrap items-center gap-2 text-sm font-medium">
          <.link
            navigate="/app"
            class="rounded-lg px-3 py-2 text-slate-100 hover:bg-slate-700 hover:text-white"
          >{gettext("Buckets")}</.link>
          <.link
            navigate="/app/keys"
            class="rounded-lg px-3 py-2 text-slate-100 hover:bg-slate-700 hover:text-white"
          >{gettext("Access keys")}</.link>
          <.link
            navigate="/app/profile"
            class="rounded-lg px-3 py-2 text-slate-100 hover:bg-slate-700 hover:text-white"
          >{gettext("Profile")}</.link>
          <.link
            navigate="/app/help"
            class="rounded-lg px-3 py-2 text-slate-100 hover:bg-slate-700 hover:text-white"
          >{gettext("Help")}</.link>
          <%= if @current_user && @current_user.role == "admin" do %>
            <span class="hidden h-5 w-px bg-slate-600 sm:block" />
            <.link
              navigate="/admin"
              class="rounded-lg px-3 py-2 text-slate-100 hover:bg-slate-700 hover:text-white"
            >Dashboard</.link>
            <.link
              navigate="/admin/users"
              class="rounded-lg px-3 py-2 text-slate-100 hover:bg-slate-700 hover:text-white"
            >Users</.link>
            <.link
              navigate="/admin/groups"
              class="rounded-lg px-3 py-2 text-slate-100 hover:bg-slate-700 hover:text-white"
            >Groups</.link>
            <.link
              navigate="/admin/buckets"
              class="rounded-lg px-3 py-2 text-slate-100 hover:bg-slate-700 hover:text-white"
            >All buckets</.link>
            <.link
              navigate="/admin/keys"
              class="rounded-lg px-3 py-2 text-slate-100 hover:bg-slate-700 hover:text-white"
            >Keys</.link>
            <.link
              navigate="/admin/audit"
              class="rounded-lg px-3 py-2 text-slate-100 hover:bg-slate-700 hover:text-white"
            >Audit</.link>
          <% end %>
        </nav>
        <div class="ml-auto flex items-center gap-3 text-sm">
          <button
            type="button"
            data-theme-toggle
            aria-label={gettext("Toggle dark mode")}
            title={gettext("Toggle dark mode")}
            class="inline-flex h-9 w-9 items-center justify-center rounded-lg border border-slate-500 text-white hover:bg-slate-700"
          >
            <.icon name="hero-sun" class="size-4 theme-icon-light" />
            <.icon name="hero-moon" class="size-4 theme-icon-dark" />
          </button>
          <%= if @current_user do %>
            <span class="inline-flex items-center gap-2 rounded-full bg-slate-800 px-3 py-1.5 text-slate-100">
              <.icon name="hero-user-circle" class="size-4" />
              <span class="font-semibold">{@current_user.username}</span>
              <span class="rounded-full bg-slate-100 dark:bg-slate-800 px-2 py-0.5 text-xs font-bold text-slate-900 dark:text-slate-100">{@current_user.role}</span>
            </span>
            <.link
              href="/logout"
              method="delete"
              class="rounded-lg border border-slate-500 px-3 py-2 font-semibold text-white hover:bg-slate-700"
            >{gettext("Sign out")}</.link>
          <% else %>
            <.link
              navigate="/login"
              class="rounded-lg bg-white px-3 py-2 font-semibold text-slate-900 hover:bg-slate-200"
            >{gettext("Sign in")}</.link>
          <% end %>
        </div>
      </div>
    </header>

    <main class="mx-auto max-w-6xl px-4 py-8">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
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
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
