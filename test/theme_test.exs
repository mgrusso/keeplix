defmodule KeeplixWeb.ThemeTest do
  @moduledoc """
  Optional dark mode (P5): toggle controls, theme init script, and
  `dark:` variants in rendered markup.
  """
  use KeeplixWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Keeplix.Accounts

  test "login page carries toggle, init script, and dark variants" do
    html = get(build_conn(), "/login") |> html_response(200)

    assert html =~ "data-theme-toggle"
    assert html =~ "__setTheme"
    assert html =~ "keeplix-theme"
    assert html =~ "prefers-color-scheme"
    assert html =~ "dark:bg-slate-900"
    assert html =~ "dark:text-slate-100"
  end

  test "app header carries the toggle" do
    {:ok, user} =
      Accounts.create_user(%{
        username: "theme-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    {:ok, _view, html} =
      build_conn()
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> live("/app/keys")

    assert html =~ "data-theme-toggle"
    assert html =~ "theme-icon-light"
    assert html =~ "theme-icon-dark"
    assert html =~ "dark:bg-slate-900"
  end

  test "primary buttons flip to light in dark mode" do
    {:ok, user} =
      Accounts.create_user(%{
        username: "theme-btn-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    {:ok, _view, html} =
      build_conn()
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> live("/app/keys")

    assert html =~ "dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300"
  end
end
