defmodule KeeplixWeb.Plugs.RateLimit do
  @moduledoc """
  IP-based brute-force protection.

  Legacy form (S3 API, XML errors): `plug KeeplixWeb.Plugs.RateLimit, :s3_ip`.
  Options form: `plug KeeplixWeb.Plugs.RateLimit, bucket: :api_ip, format: :json`.

  Blocked clients never reach the (Bcrypt-hot) authentication behind
  this plug. Failed responses (403 S3 / 401 API) are tracked; successes
  never reset counters (attacks must not interleave innocent requests).
  """
  import Plug.Conn

  alias Keeplix.RateLimit
  alias Keeplix.S3.Xml

  def init(bucket) when is_atom(bucket), do: [bucket: bucket, format: :xml]
  def init(opts) when is_list(opts), do: Keyword.merge([format: :xml], opts)

  def call(conn, opts) do
    bucket = Keyword.fetch!(opts, :bucket)

    if RateLimit.check(bucket, RateLimit.client_ip(conn)) == :blocked do
      audit(bucket, conn)

      conn
      |> then(&too_many(&1, opts))
      |> halt()
    else
      format = Keyword.get(opts, :format, :xml)

      # Failures expire via their time window; successes never reset
      # counters (that would let attacks interleave innocent requests).
      register_before_send(conn, fn conn ->
        if track_status?(format, conn.status),
          do: RateLimit.track_failure(bucket, RateLimit.client_ip(conn))

        conn
      end)
    end
  end

  defp track_status?(:xml, 403), do: true
  defp track_status?(:json, 401), do: true
  defp track_status?(_, _), do: false

  defp audit(:api_ip, conn),
    do: Keeplix.Audit.log(nil, "api.throttled", RateLimit.client_ip(conn), %{})

  defp audit(_bucket, conn),
    do: Keeplix.Audit.log(nil, "s3.throttled", RateLimit.client_ip(conn), %{})

  defp too_many(conn, opts) do
    if Keyword.get(opts, :format) == :json do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        429,
        Jason.encode!(%{
          error: %{code: "too_many_requests", message: "Too many failed attempts. Slow down."}
        })
      )
    else
      conn
      |> put_resp_content_type("application/xml")
      |> send_resp(429, Xml.error("SlowDown", "Too many failed attempts. Slow down."))
    end
  end
end
