defmodule Mix.Tasks.Keeplix.RescanUsage do
  @shortdoc "Reconciles object rows with files on disk"

  @moduledoc """
  Reconciles every bucket: adopts files without rows (legacy data, crash
  orphans), prunes rows without files, removes stale sidecars, and resets
  the usage ledger from exact aggregates.

  Run once after upgrading to object-row metadata, and whenever the
  ledger is suspected to have drifted:

      mix keeplix.rescan_usage
  """
  use Mix.Task

  alias Keeplix.{Buckets, Storage}

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    for bucket <- Buckets.list_buckets() do
      case Storage.reconcile_bucket(bucket.name) do
        {:ok, stats} ->
          Mix.shell().info(
            "rescan_usage: #{bucket.name}: adopted=#{stats.adopted} pruned=#{stats.pruned} " <>
              "usage=#{stats.usage_bytes} objects=#{stats.object_count}"
          )

        {:error, reason} ->
          Mix.shell().error("rescan_usage: #{bucket.name}: #{inspect(reason)}")
      end
    end

    :ok
  end
end
