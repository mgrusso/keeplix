defmodule Mix.Tasks.Keeplix.GcTrash do
  @shortdoc "Permanently deletes old trashed objects"

  @moduledoc """
  Purges trashed objects older than the given age (default: 30 days):

      mix keeplix.gc_trash
      mix keeplix.gc_trash --days 7 --bucket my-bucket

  Without trash, deletes go straight to permanent removal; with trash,
  this task is the second stage.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [days: :integer, bucket: :string])
    Mix.Task.run("app.start")

    days = Keyword.get(opts, :days, 30)

    buckets =
      case Keyword.get(opts, :bucket) do
        nil -> Enum.map(Keeplix.Buckets.list_buckets(), & &1.name)
        name -> [name]
      end

    total =
      Enum.reduce(buckets, 0, fn bucket, acc ->
        case Keeplix.Storage.purge_trashed_older_than(bucket, days) do
          {:ok, n} ->
            Mix.shell().info("gc_trash: #{bucket}: purged #{n} object(s)")
            acc + n

          {:error, :no_such_bucket} ->
            Mix.raise("gc_trash: no such bucket #{bucket}")
        end
      end)

    Mix.shell().info("gc_trash: purged #{total} object(s) total")
  end
end
