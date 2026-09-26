defmodule Keeplix.Storage.Object do
  use Ecto.Schema
  import Ecto.Changeset

  schema "objects" do
    field :key, :string
    field :size, :integer, default: 0
    field :etag, :string, default: ""
    field :content_type, :string
    field :version_id, :string, default: "null"
    field :tags, :string, default: "{}"
    field :acl, :string, default: "private"
    field :trashed, :boolean, default: false
    field :trashed_at, :utc_datetime
    field :is_latest, :boolean, default: true
    field :deleted, :boolean, default: false

    belongs_to :bucket, Keeplix.Buckets.Bucket

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(object, attrs) do
    object
    |> cast(attrs, [
      :key,
      :size,
      :etag,
      :content_type,
      :version_id,
      :is_latest,
      :deleted,
      :tags,
      :acl,
      :trashed,
      :trashed_at
    ])
    |> validate_required([:key, :size, :etag, :version_id])
    |> unique_constraint([:bucket_id, :key, :version_id])
    |> foreign_key_constraint(:bucket_id)
  end
end
