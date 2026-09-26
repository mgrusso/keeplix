defmodule KeeplixWeb.FileController do
  @moduledoc """
  File download bridge for the web UI (session auth, no S3 signature needed).
  """
  use KeeplixWeb, :controller

  @spec download(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download(conn, %{"bucket" => bucket, "key" => parts} = params) do
    user = conn.assigns[:current_user]
    key = Enum.join(List.wrap(parts), "/")

    with %Keeplix.Buckets.Bucket{} = b <-
           Keeplix.Buckets.get_bucket(bucket) || {:error, :no_such_bucket},
         true <- Keeplix.Buckets.can_read?(user, b),
         {:ok, stat} <- Keeplix.Storage.stat_object(bucket, key) do
      content_type = Keeplix.Storage.get_content_type(bucket, key)
      inline? = Map.has_key?(params, "preview") and previewable?(content_type)

      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header("content-disposition", disposition(key, inline?))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> maybe_sandbox(inline?)
      |> send_file(200, stat.path)
    else
      _ -> conn |> put_status(404) |> text("Not found")
    end
  end

  # Inline rendering is limited to benign types; SVG stays a download
  # (scripts in same-origin iframes would run with the session).
  defp previewable?("image/svg" <> _), do: false
  defp previewable?("image/" <> _), do: true
  defp previewable?("text/" <> _), do: true
  defp previewable?("application/pdf"), do: true
  defp previewable?(_), do: false

  defp maybe_sandbox(conn, true), do: put_resp_header(conn, "content-security-policy", "sandbox")
  defp maybe_sandbox(conn, false), do: conn

  defp disposition(key, inline?) do
    if inline?,
      do: "inline; " <> filename_params(key),
      else: "attachment; " <> filename_params(key)
  end

  # Object keys are user-controlled; never interpolate them raw into headers.
  @spec filename_params(String.t()) :: String.t()
  defp filename_params(key) do
    base = key |> Path.basename() |> String.slice(0, 100)

    safe =
      base
      |> String.replace(~r/["\r\n]/, "_")
      |> String.replace(~r/[[:cntrl:]]/, "")
      |> String.trim()

    safe = if safe == "", do: "download", else: safe
    encoded = URI.encode(base, &URI.char_unreserved?/1)
    ~s(filename="#{safe}"; filename*=UTF-8''#{encoded})
  end
end
