import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :keeplix, Keeplix.Repo,
  database: Path.expand("../keeplix_test.db", __DIR__),
  pool_size: 5,
  journal_mode: :wal,
  synchronous: :normal,
  busy_timeout: 5000,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :keeplix, KeeplixWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "QNVNhGnWvhTv3x3yi4ztjIPKndEKSvOS+lS/4tThlPJgFetxEeWmpMbYj27mFHq1",
  server: false

# Test-only Vault key for S3 secret encryption.
config :keeplix, Keeplix.Vault, key: "kYJGp52FGDrcfr53829K1os6J91b9FhOkmaDMzvyGkI="

# Never hit the network from tests; breach tests inject a stub client.
config :keeplix, Keeplix.PasswordBreach, enabled: false

# In test we don't send emails
config :keeplix, Keeplix.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# No background sweeps in test (deterministic suite; manual sweep via TrashSweeper.sweep/0).
config :keeplix, Keeplix.TrashSweeper, enabled: false
