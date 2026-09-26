defmodule Keeplix.WebAuthn.BackupCode do
  use Ecto.Schema
  import Ecto.Changeset

  schema "backup_codes" do
    field :code_hash, :string
    field :used_at, :utc_datetime

    belongs_to :user, Keeplix.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def changeset(code, attrs) do
    code
    |> cast(attrs, [:code_hash, :used_at])
    |> validate_required([:code_hash])
    |> foreign_key_constraint(:user_id)
  end
end
