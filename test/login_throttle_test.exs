defmodule KeeplixWeb.LoginThrottleTest do
  @moduledoc """
  Password-login brute-force protection (P1):

  - repeated failures block the IP/username with 429
  - a success resets the failure counter
  """
  use KeeplixWeb.ConnCase

  alias Keeplix.{Accounts, RateLimit}

  @tiny [max_attempts: 2, window_ms: 60_000, block_ms: 60_000]

  setup %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        username: "throttle-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    old = Application.get_env(:keeplix, RateLimit, [])
    Application.put_env(:keeplix, RateLimit, login_ip: @tiny, login_user: @tiny)
    RateLimit.reset_all()

    on_exit(fn ->
      Application.put_env(:keeplix, RateLimit, old)
      RateLimit.reset_all()
    end)

    {:ok, conn: conn, user: user}
  end

  test "repeated failures lead to 429", %{conn: conn, user: user} do
    bad = %{"username" => user.username, "password" => "wrong"}

    conn = post(conn, "/login", bad)
    assert conn.status == 200
    assert conn.resp_body =~ "Sign in failed"

    conn = post(conn, "/login", bad)
    assert conn.status == 200
    assert conn.resp_body =~ "Sign in failed"

    conn = post(conn, "/login", bad)
    assert conn.status == 429
    assert conn.resp_body =~ "Too many failed attempts"
  end

  test "blocked clients cannot log in even with the right password", %{
    conn: conn,
    user: user
  } do
    bad = %{"username" => user.username, "password" => "wrong"}
    post(conn, "/login", bad)
    post(conn, "/login", bad)

    conn = post(conn, "/login", %{"username" => user.username, "password" => "secret1234"})
    assert conn.status == 429
    assert get_session(conn, :user_id) == nil
  end

  test "successes do not reset failure counters", %{conn: conn, user: user} do
    bad = %{"username" => user.username, "password" => "wrong"}
    good = %{"username" => user.username, "password" => "secret1234"}

    post(conn, "/login", bad)
    conn = post(conn, "/login", good)
    assert redirected_to(conn) == "/app"

    # Counter survived the success: two more failures trip the block.
    post(conn, "/login", bad)
    conn = post(conn, "/login", bad)
    assert conn.status == 429
    assert conn.resp_body =~ "Too many failed attempts"
  end

  test "malformed credentials fail generically", %{conn: conn} do
    conn = post(conn, "/login", %{"username" => ["nested"], "password" => "x"})
    assert conn.status == 200
    assert conn.resp_body =~ "Sign in failed"
  end
end
