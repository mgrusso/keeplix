defmodule KeeplixWeb.SessionHTML do
  use KeeplixWeb, :html

  def login(assigns) do
    ~H"""
    <div class="min-h-[70vh] flex items-center justify-center px-4">
      <div class="w-full max-w-md rounded-2xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-8 shadow-sm">
        <div class="mb-6 flex items-center gap-3">
          <span class="inline-flex h-10 w-10 items-center justify-center rounded-xl bg-slate-900 text-lg font-black text-white">K</span>
          <div>
            <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">keeplix</h1>
            <p class="text-sm font-medium text-slate-700 dark:text-slate-300">
              S3-compatible storage · {gettext("Sign in")}
            </p>
          </div>
          <button
            type="button"
            data-theme-toggle
            aria-label={gettext("Toggle dark mode")}
            title={gettext("Toggle dark mode")}
            class="ml-auto inline-flex h-9 w-9 items-center justify-center rounded-lg border border-slate-300 dark:border-slate-700 text-slate-700 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-800"
          >
            <.icon name="hero-sun" class="size-4 theme-icon-light" />
            <.icon name="hero-moon" class="size-4 theme-icon-dark" />
          </button>
        </div>
        <.form for={%{}} as={:session} action="/login" method="post" id="login-form">
          <%= if msg = Phoenix.Flash.get(@flash, :error) do %>
            <div
              role="alert"
              class="mb-4 rounded-lg border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950 px-3 py-2 text-sm font-semibold text-red-800 dark:text-red-300"
            >
              {msg}
            </div>
          <% end %>
          <%= if msg = Phoenix.Flash.get(@flash, :info) do %>
            <div
              role="status"
              class="mb-4 rounded-lg border border-slate-300 dark:border-slate-700 bg-slate-100 dark:bg-slate-800 px-3 py-2 text-sm font-semibold text-slate-800 dark:text-slate-200"
            >
              {msg}
            </div>
          <% end %>
          <div class="space-y-4">
            <div>
              <label
                for="login-username"
                class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
              >{gettext("Username")}</label>
              <input
                type="text"
                name="username"
                id="login-username"
                required
                autocomplete="username"
                placeholder={gettext("e.g. admin")}
                class="h-11 w-full rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-3 text-base text-slate-900 dark:text-slate-100 placeholder:text-slate-500 dark:placeholder:text-slate-400"
              />
            </div>
            <div>
              <label
                for="login-password"
                class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
              >{gettext("Password")}</label>
              <input
                type="password"
                name="password"
                id="login-password"
                required
                autocomplete="current-password"
                class="h-11 w-full rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-3 text-base text-slate-900 dark:text-slate-100 placeholder:text-slate-500 dark:placeholder:text-slate-400"
              />
            </div>
            <button class="h-11 w-full rounded-lg bg-slate-900 text-base font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">{gettext(
              "Sign in"
            )}</button>
          </div>
        </.form>
        <%= if @oidc_enabled do %>
          <div class="mt-5 border-t border-slate-200 dark:border-slate-700 pt-4 text-center">
            <.link
              href="/auth/oidc"
              class="inline-flex h-10 items-center rounded-lg border border-slate-300 dark:border-slate-700 px-4 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
            >{gettext("Sign in with single sign-on")}</.link>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
