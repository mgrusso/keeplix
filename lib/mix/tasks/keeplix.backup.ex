defmodule Mix.Tasks.Keeplix.Backup do
  @shortdoc "Creates a compressed backup of data dir and database"

  @moduledoc """
  Creates a timestamped `keeplix-backup-*.tar.gz` containing the object
  data directory and a transaction-consistent SQLite snapshot:

      mix keeplix.backup
      mix keeplix.backup --output-dir /var/backups/keeplix

  The database is snapshotted with `VACUUM INTO` (single consistent
  `.db` file, no WAL sidecars needed), so backups stay valid under
  concurrent writes. Object files are copied without locking; for
  strict point-in-time consistency stop writes during the backup or
  snapshot the underlying volume instead.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [output_dir: :string])
    Mix.Task.run("app.start")

    data_dir = Keeplix.Storage.data_dir()
    db_path = Application.fetch_env!(:keeplix, Keeplix.Repo)[:database]
    out_dir = Keyword.get(opts, :output_dir, File.cwd!())
    File.mkdir_p!(out_dir)

    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    archive = Path.join(out_dir, "keeplix-backup-#{stamp}.tar.gz")
    snapshot = Path.join(out_dir, ".keeplix-backup-#{stamp}.db")

    entries = db_entries(db_path, snapshot) ++ data_entries(data_dir)

    :ok = :erl_tar.create(String.to_charlist(archive), entries, [:compressed])
    File.rm(snapshot)
    size = File.stat!(archive).size

    Mix.shell().info("backup: wrote #{archive} (#{length(entries)} entries, #{size} bytes)")
  end

  # Transaction-consistent snapshot: a single .db file, no WAL sidecars.
  # VACUUM INTO takes no bound parameters, so the path is quoted manually.
  defp db_entries(db_path, snapshot) do
    unless File.regular?(db_path) do
      Mix.raise("backup: database not found at #{db_path}")
    end

    quoted = "'" <> String.replace(snapshot, "'", "''") <> "'"
    %{rows: _} = Keeplix.Repo.query!("VACUUM INTO #{quoted}")

    [{String.to_charlist("db/" <> Path.basename(db_path)), String.to_charlist(snapshot)}]
  end

  defp data_entries(data_dir) do
    if File.dir?(data_dir) do
      (Path.wildcard(Path.join(data_dir, "**/*")) ++ [data_dir])
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn path ->
        {String.to_charlist("data/" <> Path.relative_to(path, data_dir)),
         String.to_charlist(path)}
      end)
    else
      []
    end
  end
end
