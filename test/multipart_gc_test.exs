defmodule Keeplix.MultipartGcTest do
  @moduledoc """
  Abandoned multipart uploads are collected by age; foreign files are
  never touched (P2).
  """
  use Keeplix.DataCase

  alias Keeplix.Storage

  test "removes stale uploads and keeps fresh ones" do
    {:ok, old_id} = Storage.create_multipart("no-such-bucket", "old.bin")
    {:ok, new_id} = Storage.create_multipart("no-such-bucket", "new.bin")

    old_dir = Path.join(Storage.multipart_dir(), old_id)
    new_dir = Path.join(Storage.multipart_dir(), new_id)
    File.touch!(old_dir, {{2001, 1, 1}, {0, 0, 0}})

    assert {:ok, 1} = Storage.abort_stale_multiparts(3600)
    refute File.dir?(old_dir)
    assert File.dir?(new_dir)

    Storage.abort_multipart(new_id)
  end

  test "ignores foreign files and missing directories" do
    junk = Path.join(Storage.multipart_dir(), "not-an-upload")
    File.mkdir_p!(junk)
    File.touch!(junk, {{2001, 1, 1}, {0, 0, 0}})

    assert {:ok, 0} = Storage.abort_stale_multiparts(3600)
    assert File.dir?(junk)

    File.rm_rf!(junk)
  end

  test "staging lives inside DATA_DIR and old files are swept" do
    assert String.starts_with?(Storage.staging_dir(), Storage.data_dir())

    old = Path.join(Storage.staging_dir(), "keeplix-old")
    fresh = Path.join(Storage.staging_dir(), "keeplix-fresh")
    File.write!(old, "x")
    File.write!(fresh, "x")
    File.touch!(old, {{2001, 1, 1}, {0, 0, 0}})

    assert {:ok, 1} = Storage.clean_staging(3600)
    refute File.exists?(old)
    assert File.exists?(fresh)
    File.rm(fresh)
  end
end
