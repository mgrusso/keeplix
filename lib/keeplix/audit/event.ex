defmodule Keeplix.Audit.Event do
  use Ecto.Schema
  import Ecto.Changeset

  schema "audit_events" do
    field :actor_username, :string
    field :action, :string
    field :target, :string
    field :meta, :string

    belongs_to :actor, Keeplix.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:actor_id, :actor_username, :action, :target, :meta])
    |> validate_required([:action])
  end
end
