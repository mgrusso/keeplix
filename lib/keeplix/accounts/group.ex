defmodule Keeplix.Accounts.Group do
  use Ecto.Schema
  import Ecto.Changeset

  schema "groups" do
    field :name, :string
    field :description, :string

    many_to_many :users, Keeplix.Accounts.User,
      join_through: Keeplix.Accounts.Membership,
      join_keys: [group_id: :id, user_id: :id]

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 64)
    |> validate_format(:name, ~r/^[a-zA-Z0-9._-]+$/)
    |> unique_constraint(:name)
  end
end
