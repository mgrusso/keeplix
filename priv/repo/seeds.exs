# Seeds for keeplix.
# Creates an initial admin from environment variables:
#   ADMIN_USERNAME (default: admin)
#   ADMIN_PASSWORD (no default: a random password is generated and printed
#     unless you set one explicitly)
import Ecto.Query

alias Keeplix.Repo
alias Keeplix.Accounts

admin_user = System.get_env("ADMIN_USERNAME", "admin")

{admin_pass, generated?} =
  case Accounts.seed_admin_password() do
    {:provided, pass} -> {pass, false}
    {:generated, pass} -> {pass, true}
  end

if generated? do
  IO.puts("ADMIN_PASSWORD is not set - generated password for #{admin_user}: #{admin_pass}")
  IO.puts("Set ADMIN_PASSWORD explicitly to choose your own.")
end

unless Accounts.get_user_by_username(admin_user) do
  case Accounts.create_user(%{
         username: admin_user,
         password: admin_pass,
         role: "admin",
         display_name: "Administrator"
       }) do
    {:ok, _} -> IO.puts("Admin #{admin_user} created.")
    {:error, cs} -> IO.inspect(cs.errors, label: "Admin seed failed")
  end
end
