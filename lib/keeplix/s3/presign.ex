defmodule Keeplix.S3.Presign do
  @moduledoc """
  Generates SigV4 presigned URLs so objects can be shared from the web UI.

  The canonicalization must match `Keeplix.S3.Auth` exactly; roundtrip
  tests guard against drift. URLs are bound to the signer's host and to
  one of the user's active access keys (revoking the key kills the link).
  """

  alias Keeplix.Accounts

  @algo "AWS4-HMAC-SHA256"
  @region "us-east-1"
  @service "s3"
  @max_expiry 7 * 24 * 3_600

  @spec url(Accounts.User.t(), String.t(), String.t(), pos_integer(), String.t()) ::
          {:ok, String.t()} | {:error, :no_active_key}
  def url(user, bucket, key, expires_in_seconds, base_url) do
    with %Accounts.AccessKey{} = key_rec <- newest_active_key(user),
         {:ok, secret} <- Accounts.key_secret(key_rec) do
      expires = expires_in_seconds |> max(1) |> min(@max_expiry)
      amz_date = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
      date = String.slice(amz_date, 0, 8)
      scope = "#{date}/#{@region}/#{@service}/aws4_request"
      credential = "#{key_rec.access_key_id}/#{scope}"
      host = signed_host(base_url)

      # Encoded once here; the server encodes the decoded path the same way.
      path = "/" <> bucket <> "/" <> encode_key_path(key)

      params = %{
        "X-Amz-Algorithm" => @algo,
        "X-Amz-Credential" => credential,
        "X-Amz-Date" => amz_date,
        "X-Amz-Expires" => to_string(expires),
        "X-Amz-SignedHeaders" => "host"
      }

      qs =
        params
        |> Enum.map(fn {k, v} -> {k, to_string(v)} end)
        |> Enum.sort()
        |> Enum.map_join("&", fn {k, v} -> "#{encode(k)}=#{encode(v)}" end)

      canonical =
        ["GET", path, qs, "host:#{host}\n", "host", "UNSIGNED-PAYLOAD"] |> Enum.join("\n")

      to_sign = [@algo, amz_date, scope, sha256hex(canonical)] |> Enum.join("\n")
      sig = hmac_hex(derive_key(secret, date), to_sign)

      {:ok, "#{String.trim_trailing(base_url, "/")}#{path}?#{qs}&X-Amz-Signature=#{sig}"}
    else
      _ -> {:error, :no_active_key}
    end
  end

  # SigV4 signs the Host header verbatim, including non-standard ports.
  @spec signed_host(String.t()) :: String.t()
  def signed_host(base_url) do
    case URI.parse(base_url) do
      %{host: nil} -> "localhost"
      %{host: host, port: port} when port in [80, 443, nil] -> host
      %{host: host, port: port} -> "#{host}:#{port}"
    end
  end

  @doc """
  Public base URL of the running endpoint, for absolute share links.
  """
  @spec base_url() :: String.t()
  def base_url do
    uri = KeeplixWeb.Endpoint.url() |> URI.parse()

    case uri.port do
      port when port in [80, 443, nil] -> "#{uri.scheme}://#{uri.host}"
      port -> "#{uri.scheme}://#{uri.host}:#{port}"
    end
  end

  # ---------- internals (mirror Keeplix.S3.Auth) ----------

  defp newest_active_key(user) do
    user.id |> Accounts.list_keys_for_user() |> Enum.find(& &1.active)
  end

  defp encode_key_path(key) do
    key |> String.split("/", trim: false) |> Enum.map_join("/", &encode/1)
  end

  defp encode(s), do: URI.encode(s, &URI.char_unreserved?/1)
  defp sha256hex(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  defp hmac_hex(k, d), do: :crypto.mac(:hmac, :sha256, k, d) |> Base.encode16(case: :lower)

  defp derive_key(secret, date) do
    ("AWS4" <> secret)
    |> then(&:crypto.mac(:hmac, :sha256, &1, date))
    |> then(&:crypto.mac(:hmac, :sha256, &1, @region))
    |> then(&:crypto.mac(:hmac, :sha256, &1, @service))
    |> then(&:crypto.mac(:hmac, :sha256, &1, "aws4_request"))
  end
end
