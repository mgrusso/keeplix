import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/keeplix start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :keeplix, KeeplixWeb.Endpoint, server: true
end

config :keeplix, KeeplixWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if data_dir = System.get_env("DATA_DIR") do
  config :keeplix, data_dir: data_dir
end

if max_object_bytes = System.get_env("MAX_OBJECT_BYTES") do
  config :keeplix, :max_object_bytes, String.to_integer(max_object_bytes)
end

lifetime_overrides =
  [
    absolute_seconds:
      System.get_env("SESSION_ABSOLUTE_SECONDS") |> then(fn v -> v && String.to_integer(v) end),
    idle_seconds:
      System.get_env("SESSION_IDLE_SECONDS") |> then(fn v -> v && String.to_integer(v) end)
  ]
  |> Enum.reject(fn {_, v} -> is_nil(v) end)

unless lifetime_overrides == [] do
  config :keeplix, KeeplixWeb.Plugs.SessionLifetime, lifetime_overrides
end

if trusted = System.get_env("TRUSTED_PROXIES") do
  config :keeplix, Keeplix.RateLimit,
    trusted_proxies: trusted |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

config :keeplix, Keeplix.Oidc,
  enabled: System.get_env("OIDC_ENABLED", "false") in ["1", "true", "TRUE"],
  issuer: System.get_env("OIDC_ISSUER"),
  client_id: System.get_env("OIDC_CLIENT_ID"),
  client_secret: System.get_env("OIDC_CLIENT_SECRET"),
  redirect_uri: System.get_env("OIDC_REDIRECT_URI"),
  first_admin: System.get_env("OIDC_FIRST_ADMIN", "false") in ["1", "true", "TRUE"],
  admin_groups:
    System.get_env("OIDC_ADMIN_GROUPS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :keeplix, KeeplixWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/keeplix_web/router\.ex$"E,
        ~r"lib/keeplix_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  vault_key =
    System.get_env("ACCESS_KEY_ENCRYPTION_KEY") ||
      raise """
      environment variable ACCESS_KEY_ENCRYPTION_KEY is missing.
      Generate one with: openssl rand -base64 32
      """

  config :keeplix, Keeplix.Vault, key: vault_key

  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/keeplix/keeplix.db
      """

  # SQLite tuning (pinned explicitly, not left to adapter defaults):
  # - WAL: readers never block writers and vice versa.
  # - synchronous normal: crash-safe in WAL mode without fsync-per-commit.
  # - busy_timeout: concurrent writers wait politely instead of failing.
  # REPO_JOURNAL_MODE allows NAS/NFS deployments (WAL is broken over
  # network filesystems); non-WAL modes fall back to synchronous full.
  journal_mode =
    case System.get_env("REPO_JOURNAL_MODE", "wal") do
      mode when mode in ["wal", "delete", "truncate", "persist", "memory"] ->
        String.to_atom(mode)

      _ ->
        :wal
    end

  config :keeplix, Keeplix.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    journal_mode: journal_mode,
    synchronous: if(journal_mode == :wal, do: :normal, else: :full),
    busy_timeout: 5000

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :keeplix, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :keeplix, KeeplixWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :keeplix, KeeplixWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :keeplix, KeeplixWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :keeplix, Keeplix.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
