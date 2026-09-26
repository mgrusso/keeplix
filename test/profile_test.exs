defmodule KeeplixWeb.ProfileTest do
  @moduledoc """
  Password self-service (P3).
  """
  use KeeplixWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Keeplix.Accounts

  setup %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        username: "profile-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    {:ok, conn: conn, user: user}
  end

  test "password change works and the new password logs in", %{conn: conn, user: user} do
    {:ok, view, _} =
      conn |> Plug.Test.init_test_session(%{user_id: user.id}) |> live("/app/profile")

    html =
      render_submit(view, "save-password", %{
        "current_password" => "secret1234",
        "password" => "newsecret99",
        "password_confirmation" => "newsecret99"
      })

    assert html =~ "Password updated"

    conn =
      post(build_conn(), "/login", %{"username" => user.username, "password" => "newsecret99"})

    assert redirected_to(conn) == "/app"
  end

  test "wrong current password is rejected", %{conn: conn, user: user} do
    {:ok, view, _} =
      conn |> Plug.Test.init_test_session(%{user_id: user.id}) |> live("/app/profile")

    html =
      render_submit(view, "save-password", %{
        "current_password" => "nope",
        "password" => "newsecret99",
        "password_confirmation" => "newsecret99"
      })

    assert html =~ "Current password is wrong"
    assert {:ok, _} = Accounts.authenticate(user.username, "secret1234")
  end

  test "mismatched confirmation is rejected", %{conn: conn, user: user} do
    {:ok, view, _} =
      conn |> Plug.Test.init_test_session(%{user_id: user.id}) |> live("/app/profile")

    html =
      render_submit(view, "save-password", %{
        "current_password" => "secret1234",
        "password" => "newsecret99",
        "password_confirmation" => "other"
      })

    assert html =~ "do not match"
  end

  test "admins manage API tokens in profile", %{conn: conn} do
    {:ok, admin} =
      Accounts.create_user(%{
        username: "adm-tok-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "admin"
      })

    {:ok, view, _} =
      conn |> Plug.Test.init_test_session(%{user_id: admin.id}) |> live("/app/profile")

    assert render(view) =~ "API tokens"

    html = render_submit(view, "create-token", %{"name" => "ci"})
    assert html =~ "Copy it now"
    assert [%{name: "ci"}] = Accounts.list_api_tokens(admin.id)

    [token] = Accounts.list_api_tokens(admin.id)
    html = render_click(view, "revoke-token", %{"id" => to_string(token.id)})
    assert html =~ "revoked"
    assert Accounts.list_api_tokens(admin.id) == []
  end

  test "non-admins see no API tokens", %{conn: conn, user: user} do
    {:ok, _view, html} =
      conn |> Plug.Test.init_test_session(%{user_id: user.id}) |> live("/app/profile")

    refute html =~ "API tokens"
  end
end
