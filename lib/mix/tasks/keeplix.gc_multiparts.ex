defmodule Mix.Tasks.Keeplix.GcMultiparts do
  @shortdoc "Removes abandoned multipart uploads"

  @moduledoc """
  Removes in-flight multipart uploads and staged request bodies older
  than the given age (default: 24 hours):

      mix keeplix.gc_multiparts
      mix keeplix.gc_multiparts --max-age-hours 1

  Upload creation also triggers multipart cleanup opportunistically, so
  the task is only needed for manual runs or scheduled invocations.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [max_age_hours: :integer])
    Mix.Task.run("app.start")

    hours = Keyword.get(opts, :max_age_hours, 24)
    {:ok, uploads} = Keeplix.Storage.abort_stale_multiparts(hours * 3600)
    {:ok, staged} = Keeplix.Storage.clean_staging(hours * 3600)

    Mix.shell().info(
      "gc_multiparts: removed #{uploads} stale upload(s), #{staged} staged file(s)"
    )
  end
end
