defmodule Keeplix.Repo do
  use Ecto.Repo,
    otp_app: :keeplix,
    adapter: Ecto.Adapters.SQLite3
end
