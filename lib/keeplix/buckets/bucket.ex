defmodule Keeplix.Buckets.Bucket do
  use Ecto.Schema
  import Ecto.Changeset

  schema "buckets" do
    field :name, :string
    field :quota_bytes, :integer
    field :versioning, :string, default: "off"
    field :tag_set, :string, default: "{}"
    field :cors, :string, default: ""
    field :lifecycle, :string, default: ""
    field :acl, :string, default: "private"
    belongs_to :owner, Keeplix.Accounts.User
    has_many :grants, Keeplix.Buckets.Grant

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(bucket, attrs) do
    bucket
    # NOTE: :owner_id is set programmatically (put_change by the caller)
    # and must never come from user input (mass assignment).
    |> cast(attrs, [:name, :quota_bytes, :versioning, :tag_set, :cors, :lifecycle, :acl])
    |> validate_required([:name])
    |> validate_length(:name, min: 3, max: 63)
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9.-]*[a-z0-9]$/,
      message: "must be S3-compatible (lowercase, 3-63 chars)"
    )
    |> validate_number(:quota_bytes, greater_than: 0)
    |> validate_inclusion(:versioning, ["off", "enabled", "suspended"])
    |> unique_constraint(:name)
  end
end
