defmodule Keeplix.TrashSweeperTest do
  @moduledoc """
  Background trash sweep purges only objects past retention (audit F6).
  """
  use Keeplix.DataCase

  import Ecto.Query

  alias Keeplix.{Accounts, Buckets, Repo, Storage, TrashSweeper}
  alias Keeplix.Storage.Object

  setup do
    {:ok, owner} =
      Accounts.create_user(%{
        username: "sw-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "sw-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, owner)

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    old = Application.get_env(:keeplix, TrashSweeper)

    on_exit(fn ->
      if old,
        do: Application.put_env(:keeplix, TrashSweeper, old),
        else: Application.delete_env(:keeplix, TrashSweeper)
    end)

    {:ok, bucket: bucket}
  end

  test "sweep purges old trash and keeps fresh trash", %{bucket: bucket} do
    {:ok, _} = Storage.put_object(bucket, "old.txt", "old")
    {:ok, _} = Storage.put_object(bucket, "new.txt", "new")
    :ok = Storage.delete_object(bucket, "old.txt")
    :ok = Storage.delete_object(bucket, "new.txt")

    b = Buckets.get_bucket(bucket)
    past = DateTime.utc_now() |> DateTime.add(-31 * 86_400, :second)

    Repo.update_all(
      from(o in Object, where: o.bucket_id == ^b.id and o.key == "old.txt"),
      set: [trashed_at: past]
    )

    Application.put_env(:keeplix, TrashSweeper, enabled: false, retention_days: 30)

    assert TrashSweeper.sweep() == 1
    refute Storage.object_exists?(bucket, "old.txt")
    assert {:ok, [_]} = Storage.list_trash(bucket)
  end
end
