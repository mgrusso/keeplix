defmodule Keeplix.RateLimitTest do
  @moduledoc """
  Unit tests for brute-force accounting (deterministic via injected time).
  """
  use ExUnit.Case, async: false

  alias Keeplix.RateLimit

  setup do
    RateLimit.reset_all()
    old_env = Application.get_env(:keeplix, RateLimit)

    on_exit(fn ->
      if old_env do
        Application.put_env(:keeplix, RateLimit, old_env)
      else
        Application.delete_env(:keeplix, RateLimit)
      end

      RateLimit.reset_all()
    end)

    :ok
  end

  test "allows attempts below the threshold" do
    assert RateLimit.check(:login_ip, "1.2.3.4", 0) == :ok
    assert RateLimit.track_failure(:login_ip, "1.2.3.4", 0) == :ok
    assert RateLimit.check(:login_ip, "1.2.3.4", 1) == :ok
  end

  test "blocks at the threshold and unblocks after the block window" do
    for t <- 0..9, do: RateLimit.track_failure(:login_ip, "5.6.7.8", t)

    assert RateLimit.check(:login_ip, "5.6.7.8", 10) == :blocked
    # block_ms is 10 minutes by default
    assert RateLimit.check(:login_ip, "5.6.7.8", 10 + 10 * 60 * 1000 + 1) == :ok
  end

  test "window expiry resets the counter" do
    RateLimit.track_failure(:login_ip, "9.9.9.9", 0)
    # window_ms is 5 minutes by default; a later failure starts a fresh window
    RateLimit.track_failure(:login_ip, "9.9.9.9", 5 * 60 * 1000 + 1)
    assert RateLimit.check(:login_ip, "9.9.9.9", 5 * 60 * 1000 + 2) == :ok
  end

  test "reset/1 clears tracking" do
    for t <- 0..9, do: RateLimit.track_failure(:login_user, "someone", t)
    assert RateLimit.check(:login_user, "someone", 10) == :blocked
    assert RateLimit.reset(:login_user, "someone") == :ok
    assert RateLimit.check(:login_user, "someone", 10) == :ok
  end

  test "buckets are independent" do
    for t <- 0..9, do: RateLimit.track_failure(:login_ip, "7.7.7.7", t)
    assert RateLimit.check(:login_ip, "7.7.7.7", 10) == :blocked
    assert RateLimit.check(:s3_ip, "7.7.7.7", 10) == :ok
  end

  test "sweep removes expired entries only" do
    RateLimit.track_failure(:login_ip, "stale-ip", 0)
    RateLimit.track_failure(:login_ip, "fresh-ip", 1_000_000)

    assert RateLimit.sweep(1_000_000 + 1) == 1
    assert RateLimit.check(:login_ip, "stale-ip", 1_000_000 + 1) == :ok
  end

  defp conn_with(remote_ip, headers) do
    base = Plug.Test.conn(:get, "/")

    %{base | remote_ip: remote_ip, req_headers: headers}
  end

  test "X-Forwarded-For is honored behind trusted proxies" do
    conn = conn_with({127, 0, 0, 1}, [{"x-forwarded-for", "203.0.113.7"}])
    assert RateLimit.client_ip(conn) == "203.0.113.7"
  end

  test "X-Forwarded-For is ignored from untrusted peers" do
    conn = conn_with({198, 51, 100, 9}, [{"x-forwarded-for", "203.0.113.7"}])
    assert RateLimit.client_ip(conn) == "198.51.100.9"
  end

  test "chain walk takes the entry added by the trusted proxy" do
    conn = conn_with({127, 0, 0, 1}, [{"x-forwarded-for", "10.9.9.9, 203.0.113.7"}])
    assert RateLimit.client_ip(conn) == "203.0.113.7"

    chained = conn_with({127, 0, 0, 1}, [{"x-forwarded-for", "127.0.0.1"}])
    assert RateLimit.client_ip(chained) == "127.0.0.1"
  end

  test "CIDR trusted proxies are configurable" do
    Application.put_env(:keeplix, RateLimit, trusted_proxies: ["10.0.0.0/8"])

    via_proxy = conn_with({10, 1, 2, 3}, [{"x-forwarded-for", "203.0.113.7"}])
    assert RateLimit.client_ip(via_proxy) == "203.0.113.7"

    direct = conn_with({11, 0, 0, 1}, [{"x-forwarded-for", "203.0.113.7"}])
    assert RateLimit.client_ip(direct) == "11.0.0.1"
  end
end
