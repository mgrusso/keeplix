defmodule Keeplix.Accounts.ApiToken do
  use Ecto.Schema
  import Ecto.Changeset

  schema "api_tokens" do
    field :name, :string
    field :token_hash, :string
    field :prefix, :string
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :user, Keeplix.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:name, :token_hash, :prefix, :last_used_at, :expires_at])
    |> validate_required([:name, :token_hash, :prefix])
    |> validate_length(:name, min: 1, max: 64)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id)
  end
end
