defmodule KeeplixWeb.StreamingTest do
  @moduledoc """
  Streaming SigV4 bodies decode file-to-file with bounded memory, and
  oversized streamed bodies are aborted mid-stream (F2).
  """
  use KeeplixWeb.ConnCase

  import KeeplixWeb.S3Signing

  alias Keeplix.{Accounts, Buckets, Storage}
  alias Keeplix.S3.Streaming

  @empty_sha "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  setup %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        username: "stream-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    bucket = "stream-#{System.unique_integer([:positive])}"
    {:ok, _} = Buckets.create_bucket(bucket, user)
    {:ok, _, creds} = Accounts.create_access_key(user, "streaming")

    on_exit(fn -> Storage.delete_bucket(bucket) end)

    {:ok, conn: conn, bucket: bucket, creds: creds}
  end

  defp tmp_path do
    Path.join(System.tmp_dir!(), "stream-test-#{System.unique_integer([:positive])}")
  end

  defp frame(chunks) do
    Enum.map_join(chunks, "", fn
      {data, nil} ->
        "#{Integer.to_string(byte_size(data), 16) |> String.downcase()}\r\n#{data}\r\n"

      {data, sig} ->
        "#{Integer.to_string(byte_size(data), 16) |> String.downcase()};chunk-signature=#{sig}\r\n#{data}\r\n"
    end) <> "0\r\n\r\n"
  end

  # Signs chunks per the AWS streaming formula (mirrors the documented
  # algorithm; the official AWS example vectors below guard the formula).
  defp sign_chunks(chunks, secret, amz_date, seed) do
    date = String.slice(amz_date, 0, 8)
    scope = "#{date}/us-east-1/s3/aws4_request"
    key = derive_key(secret, date)

    {framed, _} =
      Enum.map_reduce(chunks ++ [<<>>], seed, fn data, prev ->
        hash = sha256hex(data)

        sts =
          Enum.join(["AWS4-HMAC-SHA256-PAYLOAD", amz_date, scope, prev, @empty_sha, hash], "\n")

        sig = hmac_hex(key, sts)
        size = Integer.to_string(byte_size(data), 16) |> String.downcase()
        {"#{size};chunk-signature=#{sig}\r\n#{data}\r\n", sig}
      end)

    Enum.join(framed)
  end

  defp streaming_ctx(secret, amz_date, seed) do
    date = String.slice(amz_date, 0, 8)

    %{
      signing_key: derive_key(secret, date),
      amz_date: amz_date,
      scope: "#{date}/us-east-1/s3/aws4_request",
      seed_signature: seed
    }
  end

  test "official AWS vectors verify" do
    secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    amz_date = "20130524T000000Z"
    seed = "4f232c4386841ef735655705268965c44a0e4690baa4adea153f7db9fa80a0a9"

    body =
      "10000;chunk-signature=ad80c730a21e5b8d04586a2213dd63b9a0e99e0e2307b0ade35a65485a288648\r\n" <>
        String.duplicate("a", 65_536) <>
        "\r\n400;chunk-signature=0055627c9e194cb4542bae2aa5492e3c1575bbb81b612b7d234b86a503ef5497\r\n" <>
        String.duplicate("a", 1024) <>
        "\r\n0;chunk-signature=b6c6ea8a5354eaf15b3cb7646744f4275b71ea724fed81ceb9323e279d449df9\r\n"

    path = tmp_path()
    File.write!(path, body)

    ctx = streaming_ctx(secret, amz_date, seed)
    assert :ok = Streaming.verify_and_decode_file!(path, ctx)
    assert File.read!(path) == String.duplicate("a", 66_560)
    File.rm(path)
  end

  test "local signer roundtrips through server verification" do
    secret = :crypto.strong_rand_bytes(30) |> Base.encode64(padding: false)
    amz_date = current_amz_date()
    seed = String.duplicate("1", 64)

    framed = sign_chunks(["streamed-", "payload"], secret, amz_date, seed)
    path = tmp_path()
    File.write!(path, framed)

    ctx = streaming_ctx(secret, amz_date, seed)
    assert :ok = Streaming.verify_and_decode_file!(path, ctx)
    assert File.read!(path) == "streamed-payload"
    File.rm(path)
  end

  test "tampered and unsigned chunks are rejected" do
    secret = :crypto.strong_rand_bytes(30) |> Base.encode64(padding: false)
    amz_date = current_amz_date()
    seed = String.duplicate("0", 64)
    ctx = streaming_ctx(secret, amz_date, seed)

    good = sign_chunks(["hello ", "world"], secret, amz_date, seed)

    tampered = String.replace(good, "world", "WRRLD", global: false)
    bad_path = tmp_path()
    File.write!(bad_path, tampered)
    assert_raise RuntimeError, fn -> Streaming.verify_and_decode_file!(bad_path, ctx) end
    File.rm(bad_path)

    wrong_ctx =
      streaming_ctx(Base.encode64(:crypto.strong_rand_bytes(30), padding: false), amz_date, seed)

    wrong_path = tmp_path()
    File.write!(wrong_path, good)

    assert_raise RuntimeError, fn ->
      Streaming.verify_and_decode_file!(
        wrong_path,
        ctx |> Map.put(:signing_key, wrong_ctx.signing_key)
      )
    end

    File.rm(wrong_path)

    unsigned_path = tmp_path()
    File.write!(unsigned_path, frame([{"hello", nil}]))
    assert_raise RuntimeError, fn -> Streaming.verify_and_decode_file!(unsigned_path, ctx) end
    File.rm(unsigned_path)
  end

  test "decode_file! handles multi-chunk bodies with extensions" do
    big = :crypto.strong_rand_bytes(200_000)
    path = tmp_path()
    File.write!(path, frame([{"hello ", nil}, {big, "deadbeef"}, {"world", nil}]))

    assert :ok = Streaming.decode_file!(path)
    assert File.read!(path) == "hello " <> big <> "world"
    File.rm(path)
  end

  test "decode_file! rejects broken framing" do
    for bad <- ["", "zz\r\nabc\r\n0\r\n\r\n", "5\r\nabc", "5\r\nabcde\r\nNOPE"] do
      path = tmp_path()
      File.write!(path, bad)

      assert_raise RuntimeError, fn -> Streaming.decode_file!(path) end

      leftovers =
        System.tmp_dir!()
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, Path.basename(path)))

      assert leftovers == [Path.basename(path)]
      File.rm(path)
    end
  end

  test "streaming PUT stores the decoded payload", %{conn: conn, bucket: bucket, creds: creds} do
    conn =
      signed_request(conn, "PUT", "/#{bucket}/s.bin",
        stream_chunks: ["streamed-", "payload"],
        creds: creds
      )

    assert conn.status == 200
    assert {:ok, %{size: 16}} = Storage.stat_object(bucket, "s.bin")
  end

  test "unsigned streaming bodies are rejected", %{conn: conn, bucket: bucket, creds: creds} do
    body = frame([{"streamed-", nil}, {"payload", nil}])

    conn =
      signed_request(conn, "PUT", "/#{bucket}/s.bin",
        body: body,
        payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD",
        creds: creds
      )

    assert conn.status == 400
    refute Storage.object_exists?(bucket, "s.bin")
  end

  defp frame_unsigned(chunks, trailers \\ [{"x-amz-checksum-crc32", "DUo3JQ=="}]) do
    framed =
      Enum.map_join(chunks, "", fn data ->
        "#{Integer.to_string(byte_size(data), 16) |> String.downcase()}\r\n#{data}\r\n"
      end)

    trailer_block = Enum.map_join(trailers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)
    framed <> "0\r\n" <> trailer_block <> "\r\n"
  end

  test "decode_file_unsigned! strips framing and trailers" do
    path = tmp_path()
    File.write!(path, frame_unsigned(["streamed-", "payload"]))
    assert :ok = Streaming.decode_file_unsigned!(path)
    assert File.read!(path) == "streamed-payload"
    File.rm(path)
  end

  test "decode_file_unsigned! tolerates missing trailer block" do
    path = tmp_path()
    File.write!(path, "10\r\nstreamed-payload\r\n0\r\n\r\n")
    assert :ok = Streaming.decode_file_unsigned!(path)
    assert File.read!(path) == "streamed-payload"
    File.rm(path)
  end

  test "decode_file_unsigned! rejects broken framing" do
    path = tmp_path()
    File.write!(path, "zz\r\nnope\r\n0\r\n\r\n")
    assert_raise RuntimeError, fn -> Streaming.decode_file_unsigned!(path) end
    File.rm(path)

    truncated = tmp_path()
    File.write!(truncated, "10\r\nshort\r\n")
    assert_raise RuntimeError, fn -> Streaming.decode_file_unsigned!(truncated) end
    File.rm(truncated)
  end

  test "unsigned-trailer PUT stores the decoded payload", %{
    conn: conn,
    bucket: bucket,
    creds: creds
  } do
    body = frame_unsigned(["streamed-", "payload"])

    conn =
      signed_request(conn, "PUT", "/#{bucket}/u.bin",
        body: body,
        payload_hash: "STREAMING-UNSIGNED-PAYLOAD-TRAILER",
        creds: creds
      )

    assert conn.status == 200
    assert {:ok, %{size: 16}} = Storage.stat_object(bucket, "u.bin")
  end

  test "oversized streamed bodies abort with 400", %{conn: conn, bucket: bucket, creds: creds} do
    old = Application.get_env(:keeplix, :max_object_bytes)
    Application.put_env(:keeplix, :max_object_bytes, 100)

    on_exit(fn ->
      if old,
        do: Application.put_env(:keeplix, :max_object_bytes, old),
        else: Application.delete_env(:keeplix, :max_object_bytes)
    end)

    conn =
      signed_request(conn, "PUT", "/#{bucket}/big.bin",
        body: String.duplicate("x", 200),
        creds: creds
      )

    assert conn.status == 400
    assert conn.resp_body =~ "TooLarge"
    refute Storage.object_exists?(bucket, "big.bin")
  end
end
