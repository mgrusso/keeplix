defmodule Keeplix.TrashSweeper do
  @moduledoc """
  Background worker: purges trashed objects older than the retention
  period, so deleted data eventually stops occupying quota.

  Config (`config :keeplix, Keeplix.TrashSweeper`):

      [enabled: true, interval_ms: 3_600_000, retention_days: 30]

  Disabled in test (see `config/test.exs`); manual runs via
  `mix keeplix.gc_trash`.
  """
  use GenServer

  require Logger

  @defaults [enabled: true, interval_ms: 3_600_000, retention_days: 30]

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    if enabled?(), do: schedule(interval_ms())
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    if enabled?(), do: schedule(interval_ms())
    {:noreply, state}
  end

  @doc """
  Runs one sweep now (used by tests and consoles).
  Returns the purged count.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    days = retention_days()

    total =
      try do
        Enum.reduce(Keeplix.Buckets.list_buckets(), 0, fn bucket, acc ->
          case Keeplix.Storage.purge_trashed_older_than(bucket.name, days) do
            {:ok, n} -> acc + n
            _ -> acc
          end
        end)
      rescue
        e ->
          Logger.warning("trash sweep failed", error: inspect(e))
          0
      end

    if total > 0, do: Logger.info("trash sweep purged #{total} object(s)")
    total
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)

  defp config, do: Application.get_env(:keeplix, __MODULE__, [])

  defp enabled?, do: Keyword.get(config(), :enabled, Keyword.fetch!(@defaults, :enabled))

  defp interval_ms,
    do: Keyword.get(config(), :interval_ms, Keyword.fetch!(@defaults, :interval_ms))

  defp retention_days,
    do: Keyword.get(config(), :retention_days, Keyword.fetch!(@defaults, :retention_days))
end
