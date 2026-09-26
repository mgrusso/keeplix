defmodule Keeplix.PasswordBreachTest do
  @moduledoc """
  Breach check uses k-anonymity fixtures, never the network (P6).
  """
  use Keeplix.DataCase, async: false

  alias Keeplix.{Accounts, PasswordBreach}

  setup do
    old = Application.get_env(:keeplix, PasswordBreach)
    Application.put_env(:keeplix, PasswordBreach, enabled: true)
    on_exit(fn -> Application.put_env(:keeplix, PasswordBreach, old) end)
    :ok
  end

  defp stub_for(password, count) do
    suffix = :crypto.hash(:sha, password) |> Base.encode16(case: :upper) |> String.slice(5, 35)

    fn _url ->
      {:ok, %{status: 200, body: "AAAAA#{suffix}:1\r\n#{suffix}:#{count}\r\n"}}
    end
  end

  test "count/2 parses range responses" do
    assert {:ok, 999} = PasswordBreach.count("hunter2", stub_for("hunter2", 999))
    assert {:ok, 0} = PasswordBreach.count("fresh-unique", stub_for("other", 5))
  end

  test "unreachable API fails open" do
    failing = fn _url -> {:error, :econnrefused} end
    assert {:error, :econnrefused} = PasswordBreach.count("hunter2", failing)
    Application.put_env(:keeplix, PasswordBreach, enabled: true, http_client: failing)
    refute PasswordBreach.breached?("hunter2")
  end

  test "breached passwords are rejected on registration" do
    Application.put_env(:keeplix, PasswordBreach,
      enabled: true,
      http_client: stub_for("pwned-password-1", 42)
    )

    assert {:error, changeset} =
             Accounts.create_user(%{username: "breached-1", password: "pwned-password-1"})

    assert %{password: ["has appeared in a data breach, choose another one"]} =
             errors_on(changeset)
  end

  test "clean passwords pass with stub" do
    Application.put_env(:keeplix, PasswordBreach,
      enabled: true,
      http_client: stub_for("something-else-entirely", 3)
    )

    assert {:ok, _} = Accounts.create_user(%{username: "clean-1", password: "fresh-unique-99"})
  end

  test "disabled check allows everything" do
    Application.put_env(:keeplix, PasswordBreach, enabled: false)
    refute PasswordBreach.breached?("password")
  end

  test "raising HTTP client fails open" do
    raising = fn _url -> raise ArgumentError, "unknown registry: Req.Finch" end
    Application.put_env(:keeplix, PasswordBreach, enabled: true, http_client: raising)
    refute PasswordBreach.breached?("hunter2")
  end
end
