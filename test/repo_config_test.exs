defmodule Keeplix.RepoConfigTest do
  @moduledoc """
  SQLite pragmas are pinned explicitly (WAL, normal sync, busy timeout).
  """
  use Keeplix.DataCase, async: false

  test "journal mode, synchronous and busy timeout" do
    assert %{rows: [["wal"]]} = Repo.query!("PRAGMA journal_mode")
    assert %{rows: [[1]]} = Repo.query!("PRAGMA synchronous")

    # Exqlite applies busy_timeout via NIF (invisible to PRAGMA reads),
    # so the pinned config value itself is asserted here.
    assert Application.get_env(:keeplix, Keeplix.Repo)[:busy_timeout] == 5000
  end
end
