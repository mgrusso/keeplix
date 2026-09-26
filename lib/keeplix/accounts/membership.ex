defmodule Keeplix.Accounts.Membership do
  use Ecto.Schema

  schema "group_memberships" do
    belongs_to :user, Keeplix.Accounts.User
    belongs_to :group, Keeplix.Accounts.Group

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
