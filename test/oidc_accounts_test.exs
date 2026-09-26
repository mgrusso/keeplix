defmodule Keeplix.OidcAccountsTest do
  @moduledoc """
  Account-safety tests for OIDC-provisioned users (P0):

  - SSO logins never reactivate suspended users
  - group memberships sync on every login, not just on signup
  - missing subject claims are rejected outright
  """
  use Keeplix.DataCase

  alias Keeplix.Accounts

  setup do
    old = Application.get_env(:keeplix, Keeplix.Oidc)
    on_exit(fn -> Application.put_env(:keeplix, Keeplix.Oidc, old) end)
    :ok
  end

  defp set_oidc_config(overrides) do
    base = Application.get_env(:keeplix, Keeplix.Oidc)
    Application.put_env(:keeplix, Keeplix.Oidc, Keyword.merge(base, overrides))
  end

  defp claims(sub, groups \\ []) do
    %{
      sub: sub,
      preferred_username: "oidc-#{sub}",
      email: "oidc-#{sub}@example.com",
      name: "OIDC #{sub}",
      groups: groups
    }
  end

  test "re-login does not reactivate a suspended user" do
    sub = "suspended-#{System.unique_integer([:positive])}"
    {:ok, user} = Accounts.upsert_oidc_user(claims(sub))
    {:ok, suspended} = Accounts.update_user(user, %{is_active: false})

    assert {:error, :inactive} = Accounts.upsert_oidc_user(claims(sub))
    assert Accounts.get_user!(suspended.id).is_active == false
  end

  test "groups sync on every login, not just on signup" do
    sub = "grouped-#{System.unique_integer([:positive])}"
    {:ok, user} = Accounts.upsert_oidc_user(claims(sub, ["team-a"]))

    assert "team-a" in Enum.map(Accounts.user_groups(user), & &1.name)

    {:ok, same} = Accounts.upsert_oidc_user(claims(sub, ["team-a", "team-b"]))
    assert same.id == user.id

    names = same |> Accounts.user_groups() |> Enum.map(& &1.name)
    assert "team-a" in names
    assert "team-b" in names
  end

  test "colliding username does not take over a local account" do
    {:ok, local} =
      Accounts.create_user(%{
        username: "takeover-target-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "admin"
      })

    claims = %{
      sub: "attacker-sub-#{System.unique_integer([:positive])}",
      preferred_username: local.username,
      email: "attacker@example.com",
      name: "Attacker",
      groups: []
    }

    assert {:error, :username_taken} = Accounts.upsert_oidc_user(claims)

    fresh = Accounts.get_user!(local.id)
    assert fresh.oidc_sub == nil
    assert fresh.role == "admin"
    assert {:ok, _} = Accounts.authenticate(local.username, "secret1234")
  end

  test "returning user keeps their account across username changes" do
    sub = "stable-sub-#{System.unique_integer([:positive])}"

    {:ok, first} =
      Accounts.upsert_oidc_user(%{
        sub: sub,
        preferred_username: "first-name-#{System.unique_integer([:positive])}",
        email: "a@example.com",
        name: "A",
        groups: []
      })

    {:ok, second} =
      Accounts.upsert_oidc_user(%{
        sub: sub,
        preferred_username: "renamed-#{System.unique_integer([:positive])}",
        email: "b@example.com",
        name: "B",
        groups: []
      })

    assert second.id == first.id
    assert second.oidc_sub == sub
  end

  test "missing subject claim is rejected" do
    bad = %{sub: nil, preferred_username: "x", email: nil, name: nil, groups: []}
    assert {:error, :invalid_claims} = Accounts.upsert_oidc_user(bad)
  end

  test "first OIDC user is not admin by default" do
    {:ok, user} = Accounts.upsert_oidc_user(claims("first-#{System.unique_integer([:positive])}"))
    assert user.role == "user"
  end

  test "first OIDC user becomes admin only with opt-in" do
    set_oidc_config(first_admin: true)

    {:ok, user} =
      Accounts.upsert_oidc_user(claims("optin-#{System.unique_integer([:positive])}"))

    assert user.role == "admin"
  end

  test "admin group membership promotes but never demotes" do
    set_oidc_config(admin_groups: ["ops"])
    sub = "mapped-#{System.unique_integer([:positive])}"

    {:ok, user} = Accounts.upsert_oidc_user(claims(sub, ["ops"]))
    assert user.role == "admin"

    # Losing the group keeps the admin role (promote-only).
    {:ok, same} = Accounts.upsert_oidc_user(claims(sub, []))
    assert same.role == "admin"

    {:ok, plain} =
      Accounts.upsert_oidc_user(claims("plain-#{System.unique_integer([:positive])}", ["team"]))

    assert plain.role == "user"
  end
end
