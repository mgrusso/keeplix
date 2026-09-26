defmodule KeeplixWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Content-Security-Policy for HTML pages.

  `unsafe-inline` scripts/styles are required by the theme snippet in the
  root layout; everything else is same-origin. User content is never
  rendered here (object bodies go through the S3 API / file bridge with
  their own sandboxing), so this policy is intentionally strict otherwise.
  """
  import Plug.Conn

  @csp Enum.join(
         [
           "default-src 'self'",
           "script-src 'self' 'unsafe-inline'",
           "style-src 'self' 'unsafe-inline'",
           "img-src 'self' data: blob:",
           "font-src 'self' data:",
           "connect-src 'self' ws: wss:",
           "frame-src 'self'",
           "object-src 'none'",
           "base-uri 'self'",
           "frame-ancestors 'self'"
         ],
         "; "
       )

  def init(_opts), do: []

  def call(conn, _) do
    put_resp_header(conn, "content-security-policy", @csp)
  end
end
