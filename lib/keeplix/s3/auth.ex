defmodule Keeplix.S3.Auth do
  @moduledoc """
  AWS Signature Version 4 verification for S3.

  Supports:
  - `Authorization: AWS4-HMAC-SHA256 ...` header
  - Presigned URLs (`X-Amz-Signature` as query parameter)
  """

  alias Keeplix.Accounts

  @algo "AWS4-HMAC-SHA256"

  # Requests with a signing timestamp outside this window are rejected,
  # otherwise captured requests could be replayed indefinitely (AWS: 15 min).
  @max_skew_seconds 15 * 60
  # AWS caps presigned URL lifetimes at 7 days.
  @max_presigned_expiry_seconds 7 * 24 * 60 * 60

  @spec s3_request?(Plug.Conn.t()) :: boolean()
  def s3_request?(conn) do
    auth = Plug.Conn.get_req_header(conn, "authorization") |> List.first()

    cond do
      is_binary(auth) and String.starts_with?(auth, @algo) -> true
      is_binary(auth) and String.starts_with?(auth, "AWS ") -> true
      Map.has_key?(conn.query_params, "X-Amz-Signature") -> true
      Map.has_key?(conn.query_params, "X-Amz-Algorithm") -> true
      true -> false
    end
  end

  @doc """
  Streaming verification context for an already-verified request.

  The header was signature-checked by `verify/2`, so re-parsing it here
  is safe. Used to verify per-chunk signatures of
  `STREAMING-AWS4-HMAC-SHA256-PAYLOAD` bodies.
  """
  @spec streaming_context(Plug.Conn.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def streaming_context(conn, secret) when is_binary(secret) do
    with [auth | _] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, %{credential: cred, signature: sig}} <- parse_auth_header(auth),
         {:ok, %{date: date, region: region, service: service}} <- parse_credential(cred),
         :ok <- check_service(service),
         amz_date when amz_date != "" <- amz_date(conn) do
      scope = "#{date}/#{region}/#{service}/aws4_request"

      {:ok,
       %{
         signing_key: derive_key(secret, date, region, service),
         amz_date: amz_date,
         scope: scope,
         seed_signature: String.downcase(sig)
       }}
    else
      _ -> {:error, :invalid_streaming_context}
    end
  end

  def streaming_context(_, _), do: {:error, :invalid_streaming_context}

  @doc """
  Verifies the signature, returns `{:ok, user, access_key}` or `{:error, reason}`.
  """
  @spec verify(Plug.Conn.t(), keyword()) ::
          {:ok, Keeplix.Accounts.User.t(), Keeplix.Accounts.AccessKey.t()} | {:error, atom()}
  def verify(conn, opts \\ []) do
    body_hash_override = Keyword.get(opts, :payload_hash, nil)

    if presigned?(conn) do
      verify_presigned(conn)
    else
      verify_header(conn, body_hash_override)
    end
  end

  defp presigned?(conn) do
    Map.has_key?(conn.query_params, "X-Amz-Signature")
  end

  # ---------- Header-Auth ----------

  defp verify_header(conn, body_hash_override) do
    with [auth | _] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, %{credential: cred, signed_headers: signed_headers, signature: sig}} <-
           parse_auth_header(auth),
         {:ok, %{access_key_id: akid, date: date, region: region, service: service}} <-
           parse_credential(cred),
         {:ok, key} <- fetch_key(akid),
         :ok <- check_service(service),
         {:ok, canonical} <-
           canonical_request(conn, signed_headers, body_hash_override),
         amz_date <- amz_date(conn),
         :ok <- check_request_time(amz_date),
         {:ok, scope} <- credential_scope(conn, date, region, service),
         string_to_sign <- build_string_to_sign(amz_date, scope, canonical),
         signing_key <- derive_key(key.secret, date, region, service),
         expected <- hmac_hex(signing_key, string_to_sign),
         true <- Plug.Crypto.secure_compare(expected, String.downcase(sig)) do
      {:ok, key.user, key}
    else
      [] -> {:error, :missing_auth}
      false -> {:error, :signature_mismatch}
      {:error, _} = err -> err
    end
  end

  defp verify_presigned(conn) do
    params = conn.query_params

    with credential when is_binary(credential) <- Map.get(params, "X-Amz-Credential"),
         signed_headers when is_binary(signed_headers) <- Map.get(params, "X-Amz-SignedHeaders"),
         signature when is_binary(signature) <- Map.get(params, "X-Amz-Signature"),
         amz_date when is_binary(amz_date) <- Map.get(params, "X-Amz-Date"),
         {:ok, %{access_key_id: akid, date: date, region: region, service: service}} <-
           parse_credential(credential),
         {:ok, key} <- fetch_key(akid),
         :ok <- check_service(service),
         :ok <- check_expiry(params, amz_date),
         {:ok, canonical} <- canonical_request_presigned(conn, signed_headers),
         scope <- "#{date}/#{region}/#{service}/aws4_request",
         string_to_sign <- build_string_to_sign(amz_date, scope, canonical),
         signing_key <- derive_key(key.secret, date, region, service),
         expected <- hmac_hex(signing_key, string_to_sign),
         true <- Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
      {:ok, key.user, key}
    else
      nil -> {:error, :missing_presigned_params}
      false -> {:error, :signature_mismatch}
      {:error, _} = err -> err
    end
  end

  defp fetch_key(akid) do
    case Accounts.get_key_by_access_id(akid) do
      nil -> {:error, :unknown_key}
      %{active: false} -> {:error, :key_disabled}
      %{user: %{is_active: false}} -> {:error, :user_inactive}
      key -> resolve_secret(key)
    end
  end

  # Secrets rest encrypted; the plaintext only ever lives in memory here.
  defp resolve_secret(key) do
    case Accounts.key_secret(key) do
      {:ok, secret} -> {:ok, %{key | secret: secret}}
      :error -> {:error, :unknown_key}
    end
  end

  defp check_service("s3"), do: :ok
  defp check_service(_), do: {:error, :invalid_service}

  defp check_expiry(params, amz_date) do
    expires = Map.get(params, "X-Amz-Expires", "0") |> to_string() |> String.to_integer()

    cond do
      expires > @max_presigned_expiry_seconds ->
        {:error, :presigned_expiry_too_long}

      true ->
        with {:ok, dt, _} <- DateTime.from_iso8601(format_amz_date(amz_date)),
             now <- DateTime.utc_now(),
             diff <- DateTime.diff(now, dt) do
          # Tolerate a little clock skew into the future, but honor expiry.
          if diff >= -@max_skew_seconds and diff <= expires,
            do: :ok,
            else: {:error, :presigned_expired}
        else
          _ -> {:error, :invalid_date}
        end
    end
  rescue
    _ -> {:error, :invalid_date}
  end

  defp check_request_time(""), do: {:error, :missing_date}

  defp check_request_time(amz_date) when is_binary(amz_date) do
    with {:ok, dt, _} <- DateTime.from_iso8601(format_amz_date(amz_date)),
         now <- DateTime.utc_now(),
         diff <- DateTime.diff(now, dt) do
      if abs(diff) <= @max_skew_seconds, do: :ok, else: {:error, :request_expired}
    else
      _ -> {:error, :invalid_date}
    end
  end

  defp format_amz_date(
         <<y::binary-4, m::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2, s::binary-2,
           "Z">>
       ) do
    "#{y}-#{m}-#{d}T#{h}:#{mi}:#{s}Z"
  end

  defp format_amz_date(other), do: other

  # ---------- Parsing ----------

  defp parse_auth_header(header) do
    case String.split(header, " ", parts: 2) do
      [@algo, rest] ->
        # Elements are comma-separated; the space after the comma is
        # optional (streaming signatures omit it), so split on "," and trim.
        parts =
          String.split(rest, ",")
          |> Map.new(fn p ->
            [k, v] = String.split(String.trim(p), "=", parts: 2)
            {String.trim(k), String.trim(v)}
          end)

        {:ok,
         %{
           credential: Map.get(parts, "Credential", ""),
           signed_headers: Map.get(parts, "SignedHeaders", ""),
           signature: Map.get(parts, "Signature", "")
         }}

      _ ->
        {:error, :invalid_auth_header}
    end
  end

  defp parse_credential(cred) do
    case String.split(cred, "/") do
      [akid, date, region, service, "aws4_request"] ->
        {:ok, %{access_key_id: akid, date: date, region: region, service: service}}

      _ ->
        {:error, :invalid_credential}
    end
  end

  defp amz_date(conn) do
    case Plug.Conn.get_req_header(conn, "x-amz-date") do
      [d | _] -> d
      [] -> ""
    end
  end

  defp credential_scope(_conn, date, region, service) do
    {:ok, "#{date}/#{region}/#{service}/aws4_request"}
  end

  # ---------- Canonical request ----------

  defp canonical_request(conn, signed_headers_str, body_hash_override) do
    method = conn.method |> String.upcase()
    uri = canonical_uri(conn.request_path)
    query = canonical_query(conn.query_string)
    headers = signed_headers_list(signed_headers_str)

    with {:ok, header_block} <- canonical_headers(conn, headers),
         {:ok, payload_hash} <- payload_hash(conn, body_hash_override) do
      signed = Enum.join(headers, ";")

      canonical =
        [method, uri, query, header_block, signed, payload_hash]
        |> Enum.join("\n")

      {:ok, canonical}
    end
  end

  defp canonical_request_presigned(conn, signed_headers_str) do
    method = conn.method |> String.upcase()
    uri = canonical_uri(conn.request_path)
    headers = signed_headers_list(signed_headers_str)

    # Bei presigned URLs wird die Signature selbst aus dem Query entfernt
    query =
      conn.query_params
      |> Map.delete("X-Amz-Signature")
      |> Enum.map(fn {k, v} -> {k, to_string(v)} end)
      |> Enum.sort()
      |> Enum.map_join("&", fn {k, v} -> "#{aws_encode(k)}=#{aws_encode(v)}" end)

    with {:ok, header_block} <- canonical_headers_presigned(conn, headers, amz_host(conn)) do
      signed = Enum.join(headers, ";")

      canonical =
        [method, uri, query, header_block, signed, "UNSIGNED-PAYLOAD"]
        |> Enum.join("\n")

      {:ok, canonical}
    end
  end

  defp amz_host(conn), do: Plug.Conn.get_req_header(conn, "host") |> List.first() || conn.host

  defp canonical_headers_presigned(conn, headers, host) do
    lines =
      Enum.map(headers, fn
        "host" ->
          "host:#{String.trim(host)}\n"

        h ->
          case Plug.Conn.get_req_header(conn, h) do
            [v | _] -> "#{h}:#{String.trim(v)}\n"
            [] -> nil
          end
      end)

    if Enum.any?(lines, &is_nil/1),
      do: {:error, :missing_signed_header},
      else: {:ok, Enum.join(lines)}
  end

  defp signed_headers_list(s) do
    s
    |> String.split(";")
    |> Enum.map(&String.downcase(String.trim(&1)))
    |> Enum.filter(&(&1 != ""))
  end

  defp canonical_headers(conn, headers) do
    lines =
      Enum.map(headers, fn
        "host" ->
          host = Plug.Conn.get_req_header(conn, "host") |> List.first() || conn.host
          "host:#{String.trim(host)}\n"

        h ->
          case Plug.Conn.get_req_header(conn, h) do
            [v | _] ->
              normalized = v |> String.trim() |> String.replace(~r/\s+/, " ")
              "#{h}:#{normalized}\n"

            [] ->
              nil
          end
      end)

    if Enum.any?(lines, &is_nil/1),
      do: {:error, :missing_signed_header},
      else: {:ok, Enum.join(lines)}
  end

  defp payload_hash(_conn, override) when is_binary(override), do: {:ok, override}

  defp payload_hash(conn, nil) do
    case Plug.Conn.get_req_header(conn, "x-amz-content-sha256") do
      [h | _] when h in ["UNSIGNED-PAYLOAD", "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"] -> {:ok, h}
      ["STREAMING-UNSIGNED-PAYLOAD-TRAILER" <> _ = h] -> {:ok, h}
      [h | _] -> {:ok, String.downcase(h)}
      [] -> {:ok, :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)}
    end
  end

  defp canonical_uri(path) do
    path
    |> String.split("/", trim: false)
    |> Enum.map(&aws_encode_segment/1)
    |> Enum.join("/")
    |> then(fn s -> if s == "", do: "/", else: s end)
  end

  defp canonical_query(""), do: ""

  defp canonical_query(qs) do
    qs
    |> String.split("&", trim: true)
    |> Enum.map(fn part ->
      case String.split(part, "=", parts: 2) do
        [k, v] -> {decode_qs_component(k), decode_qs_component(v)}
        [k] -> {decode_qs_component(k), ""}
      end
    end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{aws_encode(k)}=#{aws_encode(v)}" end)
  end

  # Query components arrive percent-encoded on the wire (e.g. prefix=keys%2F).
  # AWS canonicalization encodes the *decoded* values exactly once, so decode
  # first (treating "+" as space, like SDKs do) to avoid double encoding.
  defp decode_qs_component(s) do
    s |> String.replace("+", " ") |> URI.decode()
  end

  defp aws_encode(s) do
    URI.encode(s, &URI.char_unreserved?/1)
  end

  defp aws_encode_segment(s) do
    URI.encode(s, &URI.char_unreserved?/1)
  end

  defp build_string_to_sign(amz_date, scope, canonical) do
    hashed = :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
    Enum.join([@algo, amz_date, scope, hashed], "\n")
  end

  defp derive_key(secret, date, region, service) do
    ("AWS4" <> secret)
    |> hmac_bin(date)
    |> hmac_bin(region)
    |> hmac_bin(service)
    |> hmac_bin("aws4_request")
  end

  defp hmac_bin(key, data) when is_binary(key), do: :crypto.mac(:hmac, :sha256, key, data)

  defp hmac_hex(key, data),
    do: :crypto.mac(:hmac, :sha256, key, data) |> Base.encode16(case: :lower)
end
