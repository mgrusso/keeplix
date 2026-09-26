defmodule KeeplixWeb.Router do
  use KeeplixWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KeeplixWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug KeeplixWeb.Plugs.SecurityHeaders
    plug KeeplixWeb.Plugs.Auth, :fetch_current_user
    plug KeeplixWeb.Plugs.Locale
  end

  pipeline :authed_browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KeeplixWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug KeeplixWeb.Plugs.SecurityHeaders
    plug KeeplixWeb.Plugs.Auth, :fetch_current_user
    plug KeeplixWeb.Plugs.Locale
    plug KeeplixWeb.Plugs.Auth, :require_login
    plug KeeplixWeb.Plugs.SessionLifetime
  end

  pipeline :admin_browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KeeplixWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug KeeplixWeb.Plugs.SecurityHeaders
    plug KeeplixWeb.Plugs.Auth, :fetch_current_user
    plug KeeplixWeb.Plugs.Locale
    plug KeeplixWeb.Plugs.Auth, :require_admin
    plug KeeplixWeb.Plugs.SessionLifetime
  end

  pipeline :s3_api do
    plug :accepts, ["xml", "octet-stream", "*/*"]
    plug :fetch_query_params
    plug KeeplixWeb.Plugs.RateLimit, :s3_ip
    plug KeeplixWeb.Plugs.S3Telemetry
  end

  scope "/", KeeplixWeb do
    pipe_through :browser

    get "/login", SessionController, :login
    post "/login", SessionController, :create
    live "/login/2fa", TwoFactorLive, :index
    get "/login/2fa/finish", SessionController, :finish_2fa
    get "/auth/oidc", OidcController, :request
    get "/auth/oidc/callback", OidcController, :callback
  end

  # Unauthenticated probe. Defined before the S3 catch-all so /health
  # is never mistaken for a bucket.
  scope "/", KeeplixWeb do
    get "/health", HealthController, :check
  end

  scope "/", KeeplixWeb do
    pipe_through :authed_browser

    delete "/logout", SessionController, :delete
    # Explicit 405 so GET /logout neither logs out (CSRF) nor falls
    # through to the S3 catch-all routes below.
    get "/logout", SessionController, :logout_get
    get "/files/:bucket/*key", FileController, :download

    live_session :app,
      on_mount: [
        {KeeplixWeb.Plugs.Locale, :default},
        {KeeplixWeb.Plugs.SessionLifetime, :ensure_fresh},
        {KeeplixWeb.Plugs.Auth, :ensure_active}
      ] do
      live "/app", BucketLive.Index, :index
      live "/app/keys", KeysLive.Index, :index
      live "/app/profile", ProfileLive, :index
      live "/app/help", HelpLive, :index
      live "/app/b/:name", BucketLive.Show, :show
    end
  end

  scope "/admin", KeeplixWeb do
    pipe_through :admin_browser

    live_session :admin,
      on_mount: [
        {KeeplixWeb.Plugs.Locale, :default},
        {KeeplixWeb.Plugs.SessionLifetime, :ensure_fresh},
        {KeeplixWeb.Plugs.Auth, :ensure_admin}
      ] do
      live "/", Admin.DashboardLive, :index
      live "/users", Admin.UserLive, :index
      live "/groups", Admin.GroupLive, :index
      live "/buckets", Admin.BucketLive, :index
      live "/keys", Admin.KeysLive, :index
      live "/audit", Admin.AuditLive, :index
    end
  end

  # S3-kompatible API (Pfad-Stil). Muss nach den Web-Routen stehen,
  # damit /app, /admin, /login usw. nicht als Bucket interpretiert werden.
  # Die Dev-Routen stehen bewusst davor: Der S3-Catch-all (/:bucket/*key)
  # wuerde /dev/dashboard sonst verschlucken.
  if Application.compile_env(:keeplix, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: KeeplixWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug KeeplixWeb.Plugs.RateLimit, bucket: :api_ip, format: :json
    plug KeeplixWeb.Plugs.ApiAuth
  end

  # Management API (JSON, admin-only Basic auth). Defined before the S3
  # catch-all so /api/* never resolves as a bucket.
  scope "/api/v1", KeeplixWeb.Api do
    pipe_through :api

    resources "/users", UserController, only: [:index, :show, :create, :update, :delete] do
      resources "/keys", KeyController, only: [:index, :create, :delete]
      resources "/tokens", TokenController, only: [:index, :create, :delete]
    end

    resources "/groups", GroupController, only: [:index, :show, :create, :update, :delete]
    post "/groups/:id/members", GroupController, :add_member
    delete "/groups/:id/members/:user_id", GroupController, :remove_member

    resources "/buckets", BucketController, only: [:index, :create], param: "name"
    get "/buckets/:name", BucketController, :show
    patch "/buckets/:name", BucketController, :update
    delete "/buckets/:name", BucketController, :delete
  end

  scope "/", KeeplixWeb do
    pipe_through :s3_api

    get "/", S3Controller, :service
    options "/:bucket", S3Controller, :cors_preflight
    head "/:bucket", S3Controller, :bucket
    get "/:bucket", S3Controller, :bucket
    put "/:bucket", S3Controller, :bucket
    delete "/:bucket", S3Controller, :bucket
    post "/:bucket", S3Controller, :bucket

    options "/:bucket/*key", S3Controller, :cors_preflight
    head "/:bucket/*key", S3Controller, :object
    get "/:bucket/*key", S3Controller, :object
    put "/:bucket/*key", S3Controller, :object
    delete "/:bucket/*key", S3Controller, :object
    post "/:bucket/*key", S3Controller, :object
  end
end
