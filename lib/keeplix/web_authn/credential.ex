defmodule Keeplix.WebAuthn.Credential do
  use Ecto.Schema
  import Ecto.Changeset

  schema "webauthn_credentials" do
    field :label, :string, default: "passkey"
    field :credential_id, :string
    field :public_key, :string
    field :sign_count, :integer, default: 0
    field :aaguid, :string
    field :last_used_at, :utc_datetime

    belongs_to :user, Keeplix.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:label, :credential_id, :public_key, :sign_count, :aaguid, :last_used_at])
    |> validate_required([:credential_id, :public_key])
    |> validate_length(:label, min: 1, max: 64)
    |> unique_constraint(:credential_id)
    |> foreign_key_constraint(:user_id)
  end
end
