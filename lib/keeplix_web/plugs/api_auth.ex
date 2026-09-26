defmodule KeeplixWeb.Plugs.ApiAuth do
  @moduledoc """
  Authentication for the management API (`/api/v1`).

  Two schemes (stateless, use TLS):

  - `Authorization: Bearer <personal-access-token>` — the 2FA-safe
    path; tokens are created in the profile UI or via the API.
  - HTTP Basic (username + password) — only when the admin has **no**
    WebAuthn second factor enrolled. Password-only API access for
    2FA-protected admins is rejected (`2fa_required`): a stolen
    password must not bypass the second factor.

  Only active admins are admitted in both cases.
  """
  import Plug.Conn

  alias Keeplix.{Accounts, WebAuthn}

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> bearer(conn, String.trim(token))
      ["Basic " <> encoded] -> basic(conn, encoded)
      _ -> deny(conn, "Admin credentials required")
    end
  end

  defp bearer(conn, token) do
    with {:ok, user} <- Accounts.verify_api_token(token),
         true <- user.role == "admin" do
      Keeplix.Audit.log(user, "api.auth_token", user.username, %{
        ip: Keeplix.RateLimit.client_ip(conn)
      })

      assign(conn, :api_user, user)
    else
      _ -> deny(conn, "Invalid or expired API token")
    end
  end

  defp basic(conn, encoded) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [username, password] <- String.split(decoded, ":", parts: 2),
         {:ok, user} <- Accounts.authenticate(username, password),
         # authenticate/2 only succeeds for active users with a password.
         true <- user.role == "admin",
         false <- WebAuthn.second_factor_required?(user) do
      assign(conn, :api_user, user)
    else
      true ->
        # Password valid, but a second factor is enrolled: password-only
        # API logins would bypass WebAuthn. Not tracked as brute force
        # (credentials were correct), but audited.
        Keeplix.Audit.log(nil, "api.auth_2fa_required", Keeplix.RateLimit.client_ip(conn), %{})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          403,
          Jason.encode!(%{
            error: %{
              code: "2fa_required",
              message: "Use a personal access token (password-only login disabled with 2FA)"
            }
          })
        )
        |> halt()

      _ ->
        # Failure counting happens in the RateLimit plug (401 tracking);
        # here we only log the attempt (Bcrypt-hot path stays behind the plug).
        Keeplix.Audit.log(nil, "api.auth_failed", Keeplix.RateLimit.client_ip(conn), %{})

        deny(conn, "Admin credentials required")
    end
  end

  defp deny(conn, message) do
    conn
    |> put_resp_header("www-authenticate", "Basic realm=\"keeplix-api\"")
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: %{code: "unauthorized", message: message}}))
    |> halt()
  end
end
