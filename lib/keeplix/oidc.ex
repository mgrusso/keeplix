defmodule Keeplix.Oidc do
  @moduledoc """
  Generic OIDC integration (e.g. authentik, Keycloak, Authelia).

  Configuration via environment variables:
  - `OIDC_ENABLED=1`
  - `OIDC_ISSUER=https://auth.example.com/application/o/keeplix/`
  - `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`
  - `OIDC_REDIRECT_URI=https://files.example.com/auth/oidc/callback`

  Flow: discovery (`/.well-known/openid-configuration`), authorization code flow,
  userinfo -> upsert via `Keeplix.Accounts.upsert_oidc_user/1`.
  """

  alias Assent.Strategy.OIDC

  @spec enabled?() :: boolean()
  def enabled? do
    (Application.get_env(:keeplix, __MODULE__, []) || []) |> Keyword.get(:enabled, false)
  end

  @spec config() :: keyword()
  def config do
    Application.get_env(:keeplix, __MODULE__, []) || []
  end

  @spec issuer() :: String.t() | nil
  def issuer, do: config()[:issuer]
  @spec client_id() :: String.t() | nil
  def client_id, do: config()[:client_id]
  @spec client_secret() :: String.t() | nil
  def client_secret, do: config()[:client_secret]
  @spec redirect_uri() :: String.t() | nil
  def redirect_uri, do: config()[:redirect_uri]

  @doc """
  Whether the very first OIDC user may become admin (opt-in via
  `OIDC_FIRST_ADMIN=1`). Default false: the admin is seeded explicitly,
  so a stranger can never win the bootstrap race.
  """
  @spec first_admin?() :: boolean()
  def first_admin?, do: config()[:first_admin] == true

  @doc """
  IdP group names whose members are promoted to local admins
  (`OIDC_ADMIN_GROUPS`, comma-separated). Promote-only: removal never
  demotes, so a changed claim cannot lock anyone out.
  """
  @spec admin_groups() :: [String.t()]
  def admin_groups, do: config()[:admin_groups] || []

  defp strategy_config do
    [
      client_id: client_id(),
      client_secret: client_secret(),
      base_url: issuer(),
      redirect_uri: redirect_uri()
    ]
  end

  defp strategy_config(extra) when is_list(extra) do
    Keyword.merge(strategy_config(), extra)
  end

  @spec authorize_url() :: {:ok, String.t(), map()} | {:error, term()}
  def authorize_url do
    if not enabled?() or is_nil(issuer()) do
      {:error, :oidc_disabled}
    else
      cfg =
        strategy_config(
          authorization_params: [scope: "openid profile email groups"],
          nonce: true,
          # PKCE (S256): the verifier travels in the session, the IdP
          # only ever sees the challenge. Assent handles both legs.
          code_verifier: true
        )

      case OIDC.authorize_url(cfg) do
        {:ok, %{url: url, session_params: sp}} -> {:ok, url, sp}
        error -> error
      end
    end
  end

  @spec callback(map(), map()) :: {:ok, Keeplix.Accounts.User.t()} | {:error, term()}
  def callback(params, session_params) do
    cfg =
      strategy_config(session_params: session_params)
      |> Keyword.put(:session_params, session_params)

    with {:ok, %{user: userinfo}} <- OIDC.callback(cfg, params) do
      claims = normalize(userinfo)
      Keeplix.Accounts.upsert_oidc_user(claims)
    end
  end

  defp normalize(userinfo) do
    %{
      sub: userinfo["sub"],
      preferred_username:
        userinfo["preferred_username"] || userinfo["nickname"] || userinfo["name"] ||
          userinfo["sub"],
      email: userinfo["email"],
      name: userinfo["name"],
      groups: userinfo["groups"] || []
    }
  end
end
