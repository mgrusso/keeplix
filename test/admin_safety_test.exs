defmodule KeeplixWeb.AdminSafetyTest do
  @moduledoc """
  Admin self-protection: no self-delete/suspend/demote, and the second
  admin stays manageable (P2).
  """
  use KeeplixWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Keeplix.Accounts

  setup %{conn: conn} do
    {:ok, admin} =
      Accounts.create_user(%{
        username: "safety-admin-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "admin"
      })

    {:ok, view, _} =
      conn
      |> Plug.Test.init_test_session(%{user_id: admin.id})
      |> live("/admin/users")

    {:ok, view: view, admin: admin}
  end

  test "demoted admin loses admin LiveViews", %{admin: admin} do
    {:ok, demoted} = Accounts.update_user(admin, %{role: "user"})

    assert {:error, {:redirect, _}} =
             build_conn()
             |> Plug.Test.init_test_session(%{user_id: demoted.id})
             |> live("/admin/users")
  end

  test "cannot suspend your own account", %{view: view, admin: admin} do
    html = render_click(view, "toggle-active", %{"id" => admin.id})
    assert html =~ "own account"
    assert Accounts.get_user!(admin.id).is_active
  end

  test "cannot demote your own account", %{view: view, admin: admin} do
    render_click(view, "select", %{"id" => admin.id})

    html =
      render_submit(view, "save-profile", %{
        "display_name" => "",
        "email" => "",
        "role" => "user"
      })

    assert html =~ "demote your own"
    assert Accounts.get_user!(admin.id).role == "admin"
  end

  test "cannot delete your own account", %{view: view, admin: admin} do
    html = render_click(view, "delete", %{"id" => admin.id})
    assert html =~ "own account"
    assert %Accounts.User{} = Accounts.get_user(admin.id)
  end

  test "a second admin stays manageable", %{view: view} do
    {:ok, other} =
      Accounts.create_user(%{
        username: "safety-admin2-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "admin"
      })

    # Demote the other admin down to user.
    render_click(view, "select", %{"id" => other.id})

    html =
      render_submit(view, "save-profile", %{
        "display_name" => "",
        "email" => "",
        "role" => "user"
      })

    assert html =~ "Profile updated"
    assert Accounts.get_user!(other.id).role == "user"

    # And back up.
    html =
      render_submit(view, "save-profile", %{
        "display_name" => "",
        "email" => "",
        "role" => "admin"
      })

    assert html =~ "Profile updated"
    assert Accounts.get_user!(other.id).role == "admin"
  end
end
