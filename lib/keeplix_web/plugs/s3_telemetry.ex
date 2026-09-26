defmodule KeeplixWeb.Plugs.S3Telemetry do
  @moduledoc """
  S3 request observability: telemetry event, slow-request warning and an
  optional S3-style access log file.

  Config (`config :keeplix`):
    `:s3_slow_ms` — warn above this duration (default 2000).
    `:s3_access_log` — append access lines to this path (default nil = off).
  """
  import Plug.Conn

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    start = System.monotonic_time()

    register_before_send(conn, fn conn ->
      duration_ms =
        System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)

      :telemetry.execute(
        [:keeplix, :s3, :request],
        %{duration: duration_ms},
        %{method: conn.method, path: conn.request_path, status: conn.status, bucket: bucket(conn)}
      )

      if duration_ms >= slow_ms() do
        Logger.warning("slow s3 request",
          method: conn.method,
          path: conn.request_path,
          status: conn.status,
          duration_ms: duration_ms
        )
      end

      if path = access_log_path(), do: append_access_log(path, conn, duration_ms)

      conn
    end)
  end

  defp bucket(conn), do: conn.path_params["bucket"] || conn.params["bucket"]

  defp slow_ms, do: Application.get_env(:keeplix, :s3_slow_ms, 2_000)

  defp access_log_path, do: Application.get_env(:keeplix, :s3_access_log)

  # `bucket [time] ip method "path" status bytes duration-ms`
  defp append_access_log(path, conn, duration_ms) do
    line =
      "#{bucket(conn) || "-"} [#{DateTime.utc_now() |> DateTime.to_iso8601()}] " <>
        "#{peer_ip(conn)} #{conn.method} \"#{conn.request_path}\" #{conn.status} " <>
        "#{response_bytes(conn)} #{duration_ms}ms\n"

    File.write(path, line, [:append])
  rescue
    e -> Logger.warning("s3 access log write failed", path: path, error: inspect(e))
  end

  defp peer_ip(conn) do
    case conn.remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      other -> inspect(other)
    end
  end

  defp response_bytes(conn) do
    case get_resp_header(conn, "content-length") do
      [len | _] -> len
      [] -> byte_size(conn.resp_body || "")
    end
  end
end
