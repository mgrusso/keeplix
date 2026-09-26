defmodule Keeplix.SeedAdminPasswordTest do
  @moduledoc """
  No default admin password: seeds use the explicit env value or generate
  a random one (P1).
  """
  use ExUnit.Case, async: true

  alias Keeplix.Accounts

  setup do
    old = System.get_env("ADMIN_PASSWORD")

    on_exit(fn ->
      if old, do: System.put_env("ADMIN_PASSWORD", old), else: System.delete_env("ADMIN_PASSWORD")
    end)

    :ok
  end

  test "explicit password is used as-is" do
    System.put_env("ADMIN_PASSWORD", "my-secret")
    assert {:provided, "my-secret"} = Accounts.seed_admin_password()
  end

  test "missing password generates a random one" do
    System.delete_env("ADMIN_PASSWORD")
    assert {:generated, pass1} = Accounts.seed_admin_password()
    assert {:generated, pass2} = Accounts.seed_admin_password()
    assert is_binary(pass1) and byte_size(pass1) >= 24
    assert pass1 != pass2
  end

  test "empty password counts as missing" do
    System.put_env("ADMIN_PASSWORD", "")
    assert {:generated, _} = Accounts.seed_admin_password()
  end
end
