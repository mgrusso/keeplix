defmodule Keeplix.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :email, :string
    field :password_hash, :string
    field :password, :string, virtual: true
    field :role, :string, default: "user"
    field :display_name, :string
    field :is_active, :boolean, default: true
    field :oidc_sub, :string
    field :locale, :string, default: "en"

    has_many :access_keys, Keeplix.Accounts.AccessKey

    many_to_many :groups, Keeplix.Accounts.Group,
      join_through: Keeplix.Accounts.Membership,
      join_keys: [user_id: :id, group_id: :id]

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email, :display_name, :role, :is_active, :oidc_sub, :locale])
    |> validate_required([:username])
    |> validate_format(:username, ~r/^[a-zA-Z0-9._-]+$/, message: "only letters, numbers, . _ -")
    |> validate_length(:username, min: 2, max: 64)
    |> validate_inclusion(:role, ["admin", "user"])
    |> validate_inclusion(:locale, ["en", "de"])
    |> unique_constraint(:username)
    |> unique_constraint(:oidc_sub)
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email, :display_name, :role, :is_active, :oidc_sub, :password])
    |> validate_required([:username])
    |> validate_length(:password, min: 8, max: 128)
    |> put_password_hash()
    |> validate_required([:password_hash])
    |> validate_inclusion(:role, ["admin", "user"])
    |> unique_constraint(:username)
  end

  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 128)
    |> put_password_hash()
  end

  defp put_password_hash(changeset) do
    if password = get_change(changeset, :password) do
      put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(password))
    else
      changeset
    end
  end

  def admin?(%__MODULE__{role: "admin"}), do: true
  def admin?(_), do: false
end
