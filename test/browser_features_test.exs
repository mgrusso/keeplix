defmodule KeeplixWeb.BrowserFeaturesTest do
  @moduledoc """
  Bucket browser features (P3): prefix search, sorting, paging, bulk
  delete, rename, copy/move, preview headers, presigned share links.
  """
  use KeeplixWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Keeplix.{Accounts, Buckets, S3.Auth, S3.Presign, Storage}

  setup %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        username: "feat-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "feat-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, user)

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    {:ok, conn: conn, user: user, bucket: bucket}
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp put_objects(bucket, pairs) do
    Enum.each(pairs, fn {key, content} ->
      :ok = Storage.put_object(bucket, key, content) |> elem(0)
    end)
  end

  defp html_order(html, keys) do
    Enum.map(keys, fn k ->
      case :binary.match(html, k) do
        {pos, _} -> pos
        :nomatch -> -1
      end
    end)
  end

  test "nested objects show basename prominently with full path", %{
    conn: conn,
    user: user,
    bucket: bucket
  } do
    put_objects(bucket, [{"dir/sub/report-2026.pdf", "data"}])
    {:ok, _view, html} = conn |> login(user) |> live("/app/b/#{bucket}?prefix=dir%2Fsub%2F")

    assert html =~ "report-2026.pdf"
    assert html =~ "dir/sub/report-2026.pdf"
    assert html =~ "title=\"dir/sub/report-2026.pdf\""
  end

  test "prefix search narrows results", %{conn: conn, user: user, bucket: bucket} do
    put_objects(bucket, [{"apple.txt", "a"}, {"apricot.txt", "b"}, {"banana.txt", "c"}])
    {:ok, view, _} = conn |> login(user) |> live("/app/b/#{bucket}")

    html = render_submit(view, :search, %{"q" => "apr"})
    assert html =~ "apricot.txt"
    refute html =~ "apple.txt"
    refute html =~ "banana.txt"
  end

  test "sorting by size reorders entries", %{conn: conn, user: user, bucket: bucket} do
    put_objects(bucket, [{"a.txt", "1"}, {"b.txt", "123456789"}, {"c.txt", "12345"}])
    {:ok, view, _} = conn |> login(user) |> live("/app/b/#{bucket}")

    render_click(view, :sort, %{"by" => "size"})
    html = render_click(view, :sort, %{"by" => "size"})
    [pb, pc, pa] = html_order(html, ["b.txt", "c.txt", "a.txt"])
    assert pb >= 0 and pc >= 0 and pa >= 0
    assert pb < pc and pc < pa
  end

  test "paging splits large listings", %{conn: conn, user: user, bucket: bucket} do
    for n <- 1..55 do
      :ok =
        Storage.put_object(bucket, "f#{String.pad_leading(to_string(n), 3, "0")}.txt", "x")
        |> elem(0)
    end

    {:ok, view, _} = conn |> login(user) |> live("/app/b/#{bucket}")
    assert render(view) =~ "Page 1 of 2"

    html = render_click(view, :page, %{"page" => "2"})
    assert html =~ "Page 2 of 2"
    assert html =~ "f055.txt"
    refute html =~ "f001.txt"
  end

  test "bulk delete removes selected objects", %{conn: conn, user: user, bucket: bucket} do
    put_objects(bucket, [{"d1.txt", "a"}, {"d2.txt", "b"}, {"keep.txt", "c"}])
    {:ok, view, _} = conn |> login(user) |> live("/app/b/#{bucket}")

    render_click(view, "toggle-select", %{"key" => "d1.txt"})
    render_click(view, "toggle-select", %{"key" => "d2.txt"})
    html = render_click(view, "delete-selected", %{})
    assert html =~ "2 object(s) moved to trash"
    refute Storage.object_exists?(bucket, "d1.txt")
    refute Storage.object_exists?(bucket, "d2.txt")
    assert Storage.object_exists?(bucket, "keep.txt")
  end

  test "rename moves the object", %{conn: conn, user: user, bucket: bucket} do
    put_objects(bucket, [{"old.txt", "data"}])
    {:ok, view, _} = conn |> login(user) |> live("/app/b/#{bucket}")

    render_click(view, "rename-open", %{"key" => "old.txt"})

    html = render_submit(view, "rename-save", %{"key" => "old.txt", "name" => "new.txt"})
    assert html =~ "Renamed"
    refute Storage.object_exists?(bucket, "old.txt")
    assert {:ok, %{size: 4}} = Storage.stat_object(bucket, "new.txt")
  end

  test "rename rejects existing targets", %{conn: conn, user: user, bucket: bucket} do
    put_objects(bucket, [{"a.txt", "a"}, {"b.txt", "b"}])
    {:ok, view, _} = conn |> login(user) |> live("/app/b/#{bucket}")

    html = render_submit(view, "rename-save", %{"key" => "a.txt", "name" => "b.txt"})
    assert html =~ "already exists"
    assert Storage.object_exists?(bucket, "a.txt")
  end

  test "copy and move across buckets", %{conn: conn, user: user, bucket: bucket} do
    {:ok, _} = Buckets.create_bucket("#{bucket}-dest", user)
    on_exit(fn -> Storage.delete_bucket("#{bucket}-dest") end)
    put_objects(bucket, [{"src.txt", "payload"}])
    {:ok, view, _} = conn |> login(user) |> live("/app/b/#{bucket}")

    render_click(view, "copy-open", %{"key" => "src.txt"})

    html =
      render_submit(view, "copy-save", %{
        "dest_bucket" => "#{bucket}-dest",
        "dest_key" => "copied.txt"
      })

    assert html =~ "Copied"
    assert Storage.object_exists?(bucket, "src.txt")
    assert {:ok, %{size: 7}} = Storage.stat_object("#{bucket}-dest", "copied.txt")

    render_click(view, "copy-open", %{"key" => "src.txt"})

    html =
      render_submit(view, "copy-save", %{
        "dest_bucket" => "#{bucket}-dest",
        "dest_key" => "moved.txt",
        "move" => "true"
      })

    assert html =~ "Moved"
    refute Storage.object_exists?(bucket, "src.txt")
    assert Storage.object_exists?("#{bucket}-dest", "moved.txt")
  end

  test "preview serves inline for benign types", %{conn: conn, user: user, bucket: bucket} do
    {:ok, _} = Storage.put_object(bucket, "note.txt", "hello", content_type: "text/plain")
    {:ok, _} = Storage.put_object(bucket, "blob.bin", "binary")

    authed = login(conn, user)

    preview = get(authed, "/files/#{bucket}/note.txt?preview=1")
    assert preview.status == 200

    assert get_resp_header(preview, "content-disposition")
           |> hd()
           |> String.starts_with?("inline")

    assert get_resp_header(preview, "x-content-type-options") == ["nosniff"]

    download = get(authed, "/files/#{bucket}/blob.bin?preview=1")
    assert download.status == 200

    assert get_resp_header(download, "content-disposition")
           |> hd()
           |> String.starts_with?("attachment")
  end

  test "share link roundtrips through SigV4 verification", %{
    conn: conn,
    user: user,
    bucket: bucket
  } do
    {:ok, _, _} = Accounts.create_access_key(user, "sharing")
    :ok = Storage.put_object(bucket, "shared.txt", "shared-payload") |> elem(0)

    assert {:ok, url} = Presign.url(user, bucket, "shared.txt", 3_600, "http://example.com")
    %URI{path: path, query: query} = URI.parse(url)

    conn = conn |> Map.put(:host, "example.com") |> get(path <> "?" <> query)
    assert conn.status == 200
    assert conn.resp_body == "shared-payload"

    tampered = get(conn, path <> "?" <> query <> "tamper")
    assert tampered.status == 403
  end

  test "share without an access key fails cleanly", %{conn: conn, user: user, bucket: bucket} do
    put_objects(bucket, [{"shared.txt", "x"}])
    {:ok, view, _} = conn |> login(user) |> live("/app/b/#{bucket}")

    html = render_click(view, :share, %{"key" => "shared.txt"})
    assert html =~ "needs an active access key"
  end

  test "signed host keeps non-standard ports" do
    assert Presign.signed_host("http://example.com:4000") == "example.com:4000"
    assert Presign.signed_host("https://example.com:8443/x") == "example.com:8443"
    assert Presign.signed_host("http://example.com") == "example.com"
    assert Presign.signed_host("https://example.com") == "example.com"
    assert Presign.signed_host("https://example.com:443/x") == "example.com"
    assert Presign.signed_host("garbage") == "localhost"
  end

  test "substring search matches anywhere, case-insensitive", %{
    conn: conn,
    user: user,
    bucket: bucket
  } do
    put_objects(bucket, [{"Report-2024.pdf", "a"}, {"notes.txt", "b"}, {"draft-report.md", "c"}])
    {:ok, view, _} = conn |> login(user) |> live("/app/b/#{bucket}")

    html = render_submit(view, :search, %{"q" => "report"})
    assert html =~ "Report-2024.pdf"
    assert html =~ "draft-report.md"
    refute html =~ "notes.txt"
  end

  test "bulk copy and move of selected objects", %{conn: conn, user: user, bucket: bucket} do
    put_objects(bucket, [{"b1.txt", "1"}, {"b2.txt", "22"}, {"keep.txt", "333"}])
    {:ok, view, _} = conn |> login(user) |> live("/app/b/#{bucket}")

    render_click(view, "toggle-select", %{"key" => "b1.txt"})
    render_click(view, "toggle-select", %{"key" => "b2.txt"})
    html = render_click(view, "copy-selected-open", %{})
    assert html =~ "2 object(s)"

    html =
      render_submit(view, "copy-save", %{
        "dest_bucket" => bucket,
        "dest_key" => "backup"
      })

    assert html =~ "2 object(s) copied"
    assert Storage.object_exists?(bucket, "b1.txt")
    assert Storage.object_exists?(bucket, "backup/b1.txt")
    assert Storage.object_exists?(bucket, "backup/b2.txt")

    render_click(view, "toggle-select", %{"key" => "backup/b1.txt"})
    render_click(view, "toggle-select", %{"key" => "backup/b2.txt"})
    render_click(view, "copy-selected-open", %{})

    html =
      render_submit(view, "copy-save", %{
        "dest_bucket" => bucket,
        "dest_key" => "archive",
        "move" => "true"
      })

    assert html =~ "2 object(s) moved"
    refute Storage.object_exists?(bucket, "backup/b1.txt")
    assert Storage.object_exists?(bucket, "archive/b1.txt")
    assert Storage.object_exists?(bucket, "keep.txt")
  end

  test "trash restores and purges objects", %{conn: conn, user: user, bucket: bucket} do
    put_objects(bucket, [{"t1.txt", "1"}, {"t2.txt", "22"}])
    {:ok, view, _} = conn |> login(user) |> live("/app/b/#{bucket}")

    render_click(view, "toggle-select", %{"key" => "t1.txt"})
    render_click(view, "toggle-select", %{"key" => "t2.txt"})
    html = render_click(view, "delete-selected", %{})
    assert html =~ "moved to trash"
    assert has_element?(view, "#trash-list")

    html = render_click(view, "restore-object", %{"key" => "t1.txt"})
    assert html =~ "Restored"
    assert Storage.object_exists?(bucket, "t1.txt")
    refute Storage.object_exists?(bucket, "t2.txt")

    html = render_click(view, "purge-object", %{"key" => "t2.txt"})
    assert html =~ "Permanently deleted"
    assert {:ok, []} = Storage.list_trash(bucket)
  end

  test "share link roundtrips with non-standard port", %{user: user, bucket: bucket} do
    {:ok, _, _} = Accounts.create_access_key(user, "ports")
    :ok = Storage.put_object(bucket, "port.bin", "port-payload") |> elem(0)

    assert {:ok, url} = Presign.url(user, bucket, "port.bin", 3_600, "http://example.com:4000")
    %URI{path: path, query: query} = URI.parse(url)

    # Plug.Test cannot set Host headers (forbidden); struct-update emulates
    # what Bandit/Cowboy deliver for http://example.com:4000.
    conn =
      Plug.Test.conn(:get, path <> "?" <> query)
      |> Map.put(:host, "example.com")
      |> then(&%{&1 | req_headers: [{"host", "example.com:4000"} | &1.req_headers]})
      |> Plug.Conn.fetch_query_params()

    assert {:ok, verified, _} = Auth.verify(conn)
    assert verified.id == user.id
  end
end
