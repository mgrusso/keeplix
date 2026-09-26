defmodule KeeplixWeb.OpsTest do
  @moduledoc """
  Operations surface (P6): health probe and security headers.
  """
  use KeeplixWeb.ConnCase

  test "GET /health reports database reachability" do
    conn = get(build_conn(), "/health")
    assert conn.status == 200
    assert conn.resp_body =~ "ok"
  end

  test "HTML pages carry a Content-Security-Policy" do
    conn = get(build_conn(), "/login")
    assert conn.status == 200
    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'self'"
    assert csp =~ "frame-ancestors 'self'"
    assert csp =~ "object-src 'none'"
  end
end
