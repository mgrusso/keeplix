defmodule KeeplixWeb.S3Signing do
  @moduledoc """
  AWS Signature V4 test helpers shared by S3 API tests.
  """
  import Plug.Conn

  @endpoint KeeplixWeb.Endpoint
  @host "example.com"
  @region "us-east-1"

  @spec current_amz_date() :: String.t()
  def current_amz_date, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")

  @doc """
  Signs a header-auth request and dispatches it.

  Options: `:query`, `:body`, `:creds` (`%{access_key_id, secret}`),
  `:amz_date`, `:host`, `:headers` (extra unsigned request headers),
  `:payload_hash` (override, e.g. streaming literals), `:stream_chunks`
  (list of binaries: frames and chunk-signs the body with this request's
  own seed signature).
  """
  @spec signed_request(Plug.Conn.t(), String.t(), String.t(), keyword()) :: Plug.Conn.t()
  def signed_request(conn, method, path, opts) do
    conn = fresh(conn)
    query = Keyword.get(opts, :query, "")
    creds = Keyword.fetch!(opts, :creds)
    host = Keyword.get(opts, :host, @host)
    amz_date = Keyword.get_lazy(opts, :amz_date, &current_amz_date/0)
    date = String.slice(amz_date, 0, 8)
    scope = "#{date}/#{@region}/s3/aws4_request"
    signing_key = derive_key(creds.secret, date)
    signed_headers = "host;x-amz-content-sha256;x-amz-date"

    # The canonical request covers only the payload-hash literal, never
    # the body: sign the header first (the seed), then frame chunks with it.
    {body, payload_hash, sig} =
      case Keyword.get(opts, :stream_chunks) do
        nil ->
          body = Keyword.get(opts, :body, "")
          hash = Keyword.get_lazy(opts, :payload_hash, fn -> sha256hex(body) end)

          {body, hash,
           header_signature(method, path, query, host, amz_date, scope, hash, signing_key)}

        chunks ->
          hash = "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"
          seed = header_signature(method, path, query, host, amz_date, scope, hash, signing_key)
          {frame_signed_chunks(chunks, amz_date, scope, signing_key, seed), hash, seed}
      end

    auth =
      "AWS4-HMAC-SHA256 Credential=#{creds.access_key_id}/#{scope}, " <>
        "SignedHeaders=#{signed_headers}, Signature=#{sig}"

    full_path = if query == "", do: path, else: path <> "?" <> query

    conn =
      conn
      |> Map.put(:host, host)
      |> put_req_header("x-amz-date", amz_date)
      |> put_req_header("x-amz-content-sha256", payload_hash)
      |> put_req_header("authorization", auth)
      |> maybe_content_type(method)
      |> put_extra_headers(Keyword.get(opts, :headers, []))

    Phoenix.ConnTest.dispatch(
      conn,
      @endpoint,
      method_atom(method),
      full_path,
      dispatch_body(method, body)
    )
  end

  @empty_sha "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  defp header_signature(method, path, query, host, amz_date, scope, payload_hash, signing_key) do
    signed_headers = "host;x-amz-content-sha256;x-amz-date"

    canonical =
      [
        method,
        canonical_uri(path),
        canonical_query(query),
        "host:#{host}\n" <>
          "x-amz-content-sha256:#{payload_hash}\n" <>
          "x-amz-date:#{amz_date}\n",
        signed_headers,
        payload_hash
      ]
      |> Enum.join("\n")

    to_sign = "AWS4-HMAC-SHA256\n#{amz_date}\n#{scope}\n#{sha256hex(canonical)}"
    hmac_hex(signing_key, to_sign)
  end

  defp frame_signed_chunks(chunks, amz_date, scope, signing_key, seed) do
    {framed, _} =
      Enum.map_reduce(chunks ++ [<<>>], seed, fn data, prev ->
        hash = sha256hex(data)

        sts =
          Enum.join(["AWS4-HMAC-SHA256-PAYLOAD", amz_date, scope, prev, @empty_sha, hash], "\n")

        sig = hmac_hex(signing_key, sts)
        size = Integer.to_string(byte_size(data), 16) |> String.downcase()
        {"#{size};chunk-signature=#{sig}\r\n#{data}\r\n", sig}
      end)

    Enum.join(framed)
  end

  @doc """
  Builds a presigned URL and dispatches a GET.

  Options: `:expires` (seconds), `:amz_date`, `:host`.
  """
  @spec presigned_get(Plug.Conn.t(), String.t(), map(), map(), keyword()) :: Plug.Conn.t()
  def presigned_get(conn, path, extra_query, creds, opts) do
    conn = fresh(conn)
    host = Keyword.get(opts, :host, @host)
    amz_date = Keyword.get_lazy(opts, :amz_date, &current_amz_date/0)
    date = String.slice(amz_date, 0, 8)
    expires = Keyword.get(opts, :expires, 3600)
    scope = "#{date}/#{@region}/s3/aws4_request"

    params =
      Map.merge(extra_query, %{
        "X-Amz-Algorithm" => "AWS4-HMAC-SHA256",
        "X-Amz-Credential" => "#{creds.access_key_id}/#{scope}",
        "X-Amz-Date" => amz_date,
        "X-Amz-Expires" => to_string(expires),
        "X-Amz-SignedHeaders" => "host"
      })

    canonical_qs =
      params
      |> Enum.map(fn {k, v} -> {k, to_string(v)} end)
      |> Enum.sort()
      |> Enum.map_join("&", fn {k, v} -> "#{aws_encode(k)}=#{aws_encode(v)}" end)

    canonical =
      ["GET", canonical_uri(path), canonical_qs, "host:#{host}\n", "host", "UNSIGNED-PAYLOAD"]
      |> Enum.join("\n")

    to_sign = "AWS4-HMAC-SHA256\n#{amz_date}\n#{scope}\n#{sha256hex(canonical)}"
    sig = hmac_hex(derive_key(creds.secret, date), to_sign)

    conn
    |> Map.put(:host, host)
    |> then(
      &Phoenix.ConnTest.dispatch(
        &1,
        @endpoint,
        :get,
        path <> "?" <> canonical_qs <> "&X-Amz-Signature=#{sig}"
      )
    )
  end

  @spec derive_key(String.t(), String.t()) :: binary()
  def derive_key(secret, date) do
    ("AWS4" <> secret)
    |> then(&:crypto.mac(:hmac, :sha256, &1, date))
    |> then(&:crypto.mac(:hmac, :sha256, &1, @region))
    |> then(&:crypto.mac(:hmac, :sha256, &1, "s3"))
    |> then(&:crypto.mac(:hmac, :sha256, &1, "aws4_request"))
  end

  # ---------- internals ----------

  # A ConnTest conn cannot be mutated once a response was sent; the S3 API
  # is stateless, so start over instead of crashing.
  defp fresh(%Plug.Conn{state: :unset} = conn), do: conn
  defp fresh(_conn), do: Phoenix.ConnTest.build_conn()

  # Content-Type is not part of the signed headers; ConnTest just
  # requires one whenever a binary body is dispatched.
  defp maybe_content_type(conn, method) when method in ["PUT", "POST"] do
    put_req_header(conn, "content-type", "application/octet-stream")
  end

  defp maybe_content_type(conn, _method), do: conn

  defp put_extra_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
  end

  defp dispatch_body(method, body) when method in ["PUT", "POST"], do: body
  defp dispatch_body(_method, _body), do: nil

  defp method_atom("GET"), do: :get
  defp method_atom("HEAD"), do: :head
  defp method_atom("PUT"), do: :put
  defp method_atom("POST"), do: :post
  defp method_atom("DELETE"), do: :delete

  def canonical_uri(path) do
    path
    |> String.split("/", trim: false)
    |> Enum.map_join("/", fn seg -> URI.encode(seg, &URI.char_unreserved?/1) end)
  end

  def canonical_query(""), do: ""

  def canonical_query(qs) do
    qs
    |> String.split("&", trim: true)
    |> Enum.map(fn part ->
      case String.split(part, "=", parts: 2) do
        [k, v] -> {decode_qs(k), decode_qs(v)}
        [k] -> {decode_qs(k), ""}
      end
    end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{aws_encode(k)}=#{aws_encode(v)}" end)
  end

  defp decode_qs(s), do: s |> String.replace("+", " ") |> URI.decode()
  defp aws_encode(s), do: URI.encode(s, &URI.char_unreserved?/1)
  def sha256hex(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  def hmac_hex(k, d), do: :crypto.mac(:hmac, :sha256, k, d) |> Base.encode16(case: :lower)
end
