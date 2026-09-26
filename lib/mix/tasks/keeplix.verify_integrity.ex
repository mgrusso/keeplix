defmodule Mix.Tasks.Keeplix.VerifyIntegrity do
  @shortdoc "Verifies stored object content against the database"

  @moduledoc """
  Read-only check: every non-deleted object row must have its file with
  matching size and (single-part uploads) matching MD5 etag:

      mix keeplix.verify_integrity
      mix keeplix.verify_integrity --bucket my-bucket

  Exits non-zero when any problem is found (cron-friendly). Repair with
  `mix keeplix.rescan_usage`.
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
      Enum.reduce(
        buckets,
        %{checked: 0, missing: 0, size_mismatch: 0, etag_mismatch: 0},
        fn bucket, acc ->
          case Keeplix.Storage.verify_bucket_integrity(bucket) do
            {:ok, report} ->
              print_report(bucket, report)

              %{
                checked: acc.checked + report.checked,
                missing: acc.missing + length(report.missing),
                size_mismatch: acc.size_mismatch + length(report.size_mismatch),
                etag_mismatch: acc.etag_mismatch + length(report.etag_mismatch)
              }

            {:error, :no_such_bucket} ->
              Mix.raise("verify_integrity: no such bucket #{bucket}")
          end
        end
      )

    Mix.shell().info(
      "verify_integrity: #{total.checked} object(s) checked, " <>
        "#{total.missing} missing, #{total.size_mismatch} size mismatch(es), " <>
        "#{total.etag_mismatch} etag mismatch(es)"
    )

    if total.missing + total.size_mismatch + total.etag_mismatch > 0 do
      Mix.raise("verify_integrity: integrity problems found")
    end
  end

  defp print_report(bucket, report) do
    for key <- report.missing,
        do: Mix.shell().error("#{bucket}: missing file for #{inspect(key)}")

    for key <- report.size_mismatch,
        do: Mix.shell().error("#{bucket}: size mismatch for #{inspect(key)}")

    for key <- report.etag_mismatch,
        do: Mix.shell().error("#{bucket}: etag mismatch for #{inspect(key)}")
  end
end
