defmodule KeeplixWeb.SessionLifetimeTest do
  @moduledoc """
  Absolute and idle session lifetimes for dead views and LiveViews (P6).
  """
  use KeeplixWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Keeplix.{Accounts, Buckets, Storage}
  alias KeeplixWeb.Plugs.SessionLifetime

  test "expired?/3 decides lifetimes deterministically" do
    now = 1_000_000

    assert SessionLifetime.expired?(nil, nil, now) == :refresh
    assert SessionLifetime.expired?(now - 100, now - 100, now) == :ok
    # Absolute limit is 12h by default.
    assert SessionLifetime.expired?(now - 13 * 3_600, now - 10, now) == :expired
    # Idle limit is 30m by default.
    assert SessionLifetime.expired?(now - 100, now - 31 * 60, now) == :expired
    assert SessionLifetime.expired?(now - 100, now - 29 * 60, now) == :ok
  end

  test "expired sessions are logged out on dead views" do
    {:ok, user} =
      Accounts.create_user(%{
        username: "sess-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "sess-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, user)
    :ok = Storage.put_object(bucket, "f.txt", "x") |> elem(0)
    on_exit(fn -> Storage.delete_bucket(bucket) end)

    old = System.system_time(:second) - 13 * 3_600

    expired_conn =
      build_conn()
      |> Plug.Test.init_test_session(%{
        user_id: user.id,
        session_issued_at: old,
        session_last_seen_at: old
      })
      |> get("/files/#{bucket}/f.txt")

    assert redirected_to(expired_conn) == "/login"
    assert get_session(expired_conn, :user_id) == nil

    now = System.system_time(:second)

    fresh_conn =
      build_conn()
      |> Plug.Test.init_test_session(%{
        user_id: user.id,
        session_issued_at: now,
        session_last_seen_at: now
      })
      |> get("/files/#{bucket}/f.txt")

    assert fresh_conn.status == 200
  end

  test "expired sessions are redirected out of LiveViews" do
    {:ok, user} =
      Accounts.create_user(%{
        username: "sesslv-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    old = System.system_time(:second) - 13 * 3_600

    assert {:error, {:redirect, %{to: "/login"}}} =
             build_conn()
             |> Plug.Test.init_test_session(%{
               user_id: user.id,
               session_issued_at: old,
               session_last_seen_at: old
             })
             |> live("/app/keys")
  end
end
