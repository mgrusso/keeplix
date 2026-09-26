defmodule Mix.Tasks.Keeplix.GcLifecycle do
  @shortdoc "Deletes objects expired by lifecycle rules"

  @moduledoc """
  Applies enabled lifecycle expiration rules in every bucket (or one):

      mix keeplix.gc_lifecycle
      mix keeplix.gc_lifecycle --bucket my-bucket

  Expired objects are deleted through the normal delete path (trash,
  when enabled; delete markers on versioned buckets).
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [bucket: :string])
    Mix.Task.run("app.start")

    buckets =
      case Keyword.get(opts, :bucket) do
        nil -> Enum.map(Keeplix.Buckets.list_buckets(), & &1.name)
        name -> [name]
      end

    total =
      Enum.reduce(buckets, 0, fn bucket, acc ->
        case Keeplix.Storage.apply_lifecycle(bucket) do
          {:ok, %{expired: n}} ->
            Mix.shell().info("gc_lifecycle: #{bucket}: expired #{n} object(s)")
            acc + n

          {:error, :no_such_bucket} ->
            Mix.raise("gc_lifecycle: no such bucket #{bucket}")
        end
      end)

    Mix.shell().info("gc_lifecycle: expired #{total} object(s) total")
  end
end
