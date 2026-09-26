defmodule KeeplixWeb.CopyObjectTest do
  @moduledoc """
  S3 CopyObject and Tagging (items 1 + 3a).
  """
  use KeeplixWeb.ConnCase

  import KeeplixWeb.S3Signing

  alias Keeplix.{Accounts, Buckets, Storage}

  setup %{conn: conn} do
    {:ok, owner} =
      Accounts.create_user(%{
        username: "cp-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "cp-#{System.unique_integer([:positive])}"
    dest = "cp-dest-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, owner)
    {:ok, _} = Buckets.create_bucket(dest, owner)
    {:ok, _, creds} = Accounts.create_access_key(owner, "cp")

    on_exit(fn ->
      Storage.delete_bucket(bucket)
      Storage.delete_bucket(dest)
    end)

    put = signed_request(conn, "PUT", "/#{bucket}/src.txt", body: "payload", creds: creds)
    assert put.status == 200

    {:ok, conn: conn, bucket: bucket, dest: dest, creds: creds}
  end

  defp copy(conn, dest_bucket, dest_key, source, creds, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    query = Keyword.get(opts, :query, "")

    signed_request(conn, "PUT", "/#{dest_bucket}/#{dest_key}",
      headers: [{"x-amz-copy-source", source} | headers],
      query: query,
      creds: creds
    )
  end

  test "basic same-bucket copy", %{conn: conn, bucket: bucket, creds: creds} do
    conn = copy(conn, bucket, "dst.txt", "/#{bucket}/src.txt", creds)
    assert conn.status == 200
    assert conn.resp_body =~ "CopyObjectResult"
    assert conn.resp_body =~ "LastModified"

    get = signed_request(conn, "GET", "/#{bucket}/dst.txt", creds: creds)
    assert get.status == 200
    assert get.resp_body == "payload"
  end

  test "cross-bucket copy", %{conn: conn, bucket: bucket, dest: dest, creds: creds} do
    conn = copy(conn, dest, "x.txt", "/#{bucket}/src.txt", creds)
    assert conn.status == 200

    get = signed_request(conn, "GET", "/#{dest}/x.txt", creds: creds)
    assert get.resp_body == "payload"
  end

  test "missing source and bucket map to 404", %{conn: conn, bucket: bucket, creds: creds} do
    missing = copy(conn, bucket, "d.txt", "/#{bucket}/nope.txt", creds)
    assert missing.status == 404
    assert missing.resp_body =~ "NoSuchKey"

    nobucket = copy(conn, bucket, "d.txt", "/no-such-bucket-xyz/src.txt", creds)
    assert nobucket.status == 404
    assert nobucket.resp_body =~ "NoSuchBucket"
  end

  test "self copy requires metadata REPLACE", %{conn: conn, bucket: bucket, creds: creds} do
    bad = copy(conn, bucket, "src.txt", "/#{bucket}/src.txt", creds)
    assert bad.status == 400

    good =
      copy(conn, bucket, "src.txt", "/#{bucket}/src.txt", creds,
        headers: [{"x-amz-metadata-directive", "REPLACE"}, {"content-type", "text/plain"}]
      )

    assert good.status == 200

    head = signed_request(conn, "HEAD", "/#{bucket}/src.txt", creds: creds)
    assert head.status == 200
    assert get_resp_header(head, "content-type") |> hd() |> String.starts_with?("text/plain")
  end

  test "copy conditionals gate the copy", %{conn: conn, bucket: bucket, creds: creds} do
    get = signed_request(conn, "GET", "/#{bucket}/src.txt", creds: creds)
    [etag] = get_resp_header(get, "etag")

    denied =
      copy(conn, bucket, "c.txt", "/#{bucket}/src.txt", creds,
        headers: [{"x-amz-copy-source-if-match", "\"deadbeef\""}]
      )

    assert denied.status == 412

    allowed =
      copy(conn, bucket, "c.txt", "/#{bucket}/src.txt", creds,
        headers: [{"x-amz-copy-source-if-match", etag}]
      )

    assert allowed.status == 200
  end

  test "copy from a specific version", %{conn: conn, bucket: bucket, creds: creds} do
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    assert signed_request(conn, "PUT", "/#{bucket}",
             query: "versioning=",
             body: body,
             creds: creds
           ).status == 200

    assert signed_request(conn, "PUT", "/#{bucket}/v.txt", body: "one", creds: creds).status ==
             200

    v1 = signed_request(conn, "PUT", "/#{bucket}/v.txt", body: "two", creds: creds)
    assert v1.status == 200

    versions = Storage.list_all_versions(bucket, 10)

    v1_id =
      versions |> Enum.find(&(&1.key == "v.txt" and not &1.is_latest)) |> Map.fetch!(:version_id)

    conn =
      copy(conn, bucket, "v-copy.txt", "/#{bucket}/v.txt", creds, query: "versionId=#{v1_id}")

    assert conn.status == 200
    assert get_resp_header(conn, "x-amz-copy-source-version-id") == [v1_id]
    assert get_resp_header(conn, "x-amz-version-id") != []

    get = signed_request(conn, "GET", "/#{bucket}/v-copy.txt", creds: creds)
    assert get.resp_body == "one"
  end

  test "object tagging roundtrip", %{conn: conn, bucket: bucket, creds: creds} do
    body = ~s(<Tagging><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag></TagSet></Tagging>)

    put =
      signed_request(conn, "PUT", "/#{bucket}/src.txt",
        query: "tagging=",
        body: body,
        creds: creds
      )

    assert put.status == 200

    get = signed_request(conn, "GET", "/#{bucket}/src.txt", query: "tagging=", creds: creds)
    assert get.status == 200
    assert get.resp_body =~ "<Key>env</Key>"
    assert get.resp_body =~ "<Value>prod</Value>"

    head = signed_request(conn, "HEAD", "/#{bucket}/src.txt", creds: creds)
    assert get_resp_header(head, "x-amz-tag-count") == ["1"]

    del = signed_request(conn, "DELETE", "/#{bucket}/src.txt", query: "tagging=", creds: creds)
    assert del.status == 200

    head2 = signed_request(conn, "HEAD", "/#{bucket}/src.txt", creds: creds)
    assert get_resp_header(head2, "x-amz-tag-count") == ["0"]
  end

  test "bucket tagging roundtrip", %{conn: conn, bucket: bucket, creds: creds} do
    body = ~s(<Tagging><TagSet><Tag><Key>team</Key><Value>a</Value></Tag></TagSet></Tagging>)

    assert signed_request(conn, "PUT", "/#{bucket}", query: "tagging=", body: body, creds: creds).status ==
             200

    get = signed_request(conn, "GET", "/#{bucket}", query: "tagging=", creds: creds)
    assert get.resp_body =~ "<Key>team</Key>"
  end

  test "invalid tags rejected", %{conn: conn, bucket: bucket, creds: creds} do
    many =
      Enum.map_join(1..11, "", fn n -> "<Tag><Key>k#{n}</Key><Value>v</Value></Tag>" end)

    bad =
      signed_request(conn, "PUT", "/#{bucket}/src.txt",
        query: "tagging=",
        body: "<Tagging><TagSet>#{many}</TagSet></Tagging>",
        creds: creds
      )

    assert bad.status == 400
    assert bad.resp_body =~ "InvalidTag"
  end

  test "copy carries tags by default, REPLACE applies header tags", %{
    conn: conn,
    bucket: bucket,
    creds: creds
  } do
    body = ~s(<Tagging><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag></TagSet></Tagging>)

    assert signed_request(conn, "PUT", "/#{bucket}/src.txt",
             query: "tagging=",
             body: body,
             creds: creds
           ).status == 200

    assert copy(conn, bucket, "t1.txt", "/#{bucket}/src.txt", creds).status == 200
    assert {:ok, %{"env" => "prod"}} = Storage.get_object_tags(bucket, "t1.txt")

    assert copy(conn, bucket, "t2.txt", "/#{bucket}/src.txt", creds,
             headers: [
               {"x-amz-tagging-directive", "REPLACE"},
               {"x-amz-tagging", "stage=dev"}
             ]
           ).status == 200

    assert {:ok, %{"stage" => "dev"}} = Storage.get_object_tags(bucket, "t2.txt")
  end
end
