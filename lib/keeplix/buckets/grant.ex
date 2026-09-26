defmodule Keeplix.Buckets.Grant do
  use Ecto.Schema
  import Ecto.Changeset

  @permissions ["read", "write", "admin"]

  schema "bucket_grants" do
    belongs_to :bucket, Keeplix.Buckets.Bucket
    belongs_to :user, Keeplix.Accounts.User
    belongs_to :group, Keeplix.Accounts.Group
    field :permission, :string, default: "read"

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def permissions, do: @permissions

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:bucket_id, :user_id, :group_id, :permission])
    |> validate_required([:bucket_id, :permission])
    |> validate_inclusion(:permission, @permissions)
    |> validate_principal()
    |> foreign_key_constraint(:bucket_id)
  end

  defp validate_principal(changeset) do
    user_id = get_field(changeset, :user_id)
    group_id = get_field(changeset, :group_id)

    cond do
      user_id != nil and group_id != nil ->
        add_error(changeset, :user_id, "either user or group, not both")

      user_id == nil and group_id == nil ->
        add_error(changeset, :user_id, "user or group required")

      true ->
        changeset
    end
  end
end
