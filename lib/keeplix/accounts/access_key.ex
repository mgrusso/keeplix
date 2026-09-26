defmodule Keeplix.Accounts.AccessKey do
  use Ecto.Schema
  import Ecto.Changeset

  schema "access_keys" do
    field :access_key_id, :string
    # Legacy plaintext secret. New rows store only `:secret_enc`;
    # remaining values are re-encrypted on first use (see Accounts.key_secret/1).
    field :secret, :string
    field :secret_enc, :string
    field :description, :string
    field :active, :boolean, default: true
    field :last_used_at, :utc_datetime

    belongs_to :user, Keeplix.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(key, attrs) do
    key
    # NOTE: :user_id is set programmatically (put_change by the caller)
    # and must never come from user input (mass assignment).
    |> cast(attrs, [
      :access_key_id,
      :secret,
      :secret_enc,
      :description,
      :active,
      :last_used_at
    ])
    |> validate_required([:access_key_id, :secret_enc])
    |> unique_constraint(:access_key_id)
    |> foreign_key_constraint(:user_id)
  end
end
