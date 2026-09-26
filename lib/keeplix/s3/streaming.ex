defmodule Keeplix.S3.Streaming do
  @moduledoc """
  Decodes `STREAMING-AWS4-HMAC-SHA256-PAYLOAD` chunked request bodies.

  SDKs use this framing for PUTs over plain HTTP. Each chunk on the wire is:

      <hex-size>[;chunk-signature=<sig>]\r\n<data>\r\n

  terminated by a zero-size chunk. Only the raw payload bytes are stored.

  Modern SDKs (botocore >= 1.34, aws-cli v2) additionally send
  `STREAMING-UNSIGNED-PAYLOAD-TRAILER` framing for checksum'd uploads:

      <hex-size>\r\n<data>\r\n ... 0\r\n<trailer-lines>\r\n\r\n

  Chunks carry no per-chunk signature there (integrity rides on TLS plus
  the optional trailer checksum, which is currently accepted but not
  independently verified). `decode_file_unsigned!/1` strips this framing.


  `verify_and_decode_file!/2` additionally verifies every chunk signature
  against the HMAC chain (seed signature from the verified `Authorization`
  header), so tampered chunks are rejected even over plain HTTP. Chunks
  without a signature are rejected.

  Decoding is file-to-file with bounded reads, so arbitrarily large
  payloads never end up in memory at once.
  """

  @header_line_limit 8_192
  @copy_slice 64 * 1_024
  @empty_sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  @header_line_limit 8_192
  @copy_slice 64 * 1_024

  @doc """
  Decodes a full streaming body into the raw payload.
  Returns `{:ok, payload}` or `{:error, :invalid_streaming_body}`.
  """
  @spec decode(binary()) :: {:ok, binary()} | {:error, :invalid_streaming_body}
  def decode(data) when is_binary(data) do
    decode_chunks(data, [])
  end

  defp decode_chunks(<<>>, _acc), do: {:error, :invalid_streaming_body}

  defp decode_chunks(data, acc) do
    with {:ok, line, rest} <- read_line(data),
         {:ok, size} <- parse_size(line),
         {:ok, chunk, rest} <- take_chunk(rest, size) do
      if size == 0 do
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
      else
        decode_chunks(rest, [chunk | acc])
      end
    else
      _ -> {:error, :invalid_streaming_body}
    end
  end

  defp read_line(data) do
    case :binary.split(data, "\r\n") do
      [line, rest] -> {:ok, line, rest}
      _ -> {:error, :no_line}
    end
  end

  # Skips an optional HTTP trailer block after the zero chunk: `name: value`
  # lines terminated by a blank line (or immediate end of input).
  defp skip_trailers(data, count \\ 0)
  defp skip_trailers(_, count) when count > 16, do: {:error, :too_many_trailers}
  defp skip_trailers("", _), do: {:ok, <<>>, ""}

  defp skip_trailers(data, count) do
    case read_line(data) do
      {:ok, "", rest} -> {:ok, <<>>, rest}
      {:ok, _trailer, rest} -> skip_trailers(rest, count + 1)
      {:error, _} -> {:error, :bad_framing}
    end
  end

  defp parse_size(line) do
    line
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> Integer.parse(16)
    |> case do
      {size, ""} when size >= 0 -> {:ok, size}
      _ -> {:error, :bad_size}
    end
  end

  defp take_chunk(data, 0) do
    # Zero chunk ends the framing: either a final CRLF, EOF, or a trailer
    # block (`name: value` lines terminated by a blank line).
    case data do
      "\r\n" <> rest -> skip_trailers(rest)
      "" -> {:ok, <<>>, ""}
      _ -> {:error, :bad_framing}
    end
  end

  defp take_chunk(data, size) do
    if byte_size(data) < size + 2 do
      {:error, :truncated}
    else
      <<chunk::binary-size(^size), "\r\n", rest::binary>> = data
      {:ok, chunk, rest}
    end
  rescue
    _ -> {:error, :truncated}
  end

  @doc """
  Returns true when the request uses streaming payload framing.
  """
  @spec streaming?(Plug.Conn.t()) :: boolean()
  def streaming?(conn) do
    case Plug.Conn.get_req_header(conn, "x-amz-content-sha256") do
      ["STREAMING-AWS4-HMAC-SHA256-PAYLOAD" <> _] -> true
      _ -> false
    end
  end

  @doc """
  Returns true when the request uses unsigned streaming framing with
  trailers (`STREAMING-UNSIGNED-PAYLOAD-TRAILER`, sent by modern SDKs for
  checksum'd uploads). Chunks carry no signatures; framing is stripped by
  `decode_file_unsigned!/1`.
  """
  @spec unsigned_streaming?(Plug.Conn.t()) :: boolean()
  def unsigned_streaming?(conn) do
    case Plug.Conn.get_req_header(conn, "x-amz-content-sha256") do
      ["STREAMING-UNSIGNED-PAYLOAD-TRAILER" <> _] -> true
      _ -> false
    end
  end

  @doc """
  File-to-file variant of the unsigned-trailer framing: strips chunk sizes
  and the trailing trailer block, keeping only raw payload bytes. Raises
  on bad framing or truncation.
  """
  @spec decode_file_unsigned!(String.t()) :: :ok
  def decode_file_unsigned!(src) do
    dst = src <> ".streaming-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
    {:ok, input} = :file.open(src, [:read, :binary, :raw])

    try do
      {:ok, output} = :file.open(dst, [:write, :binary, :raw])

      try do
        copy_unsigned_chunks(input, output)
        :file.close(output)
        :file.close(input)
        File.rename!(dst, src)
        :ok
      rescue
        e ->
          :file.close(output)
          File.rm(dst)
          reraise e, __STACKTRACE__
      end
    rescue
      e ->
        :file.close(input)
        reraise e, __STACKTRACE__
    end
  end

  defp copy_unsigned_chunks(input, output) do
    case read_frame_line_eof(input) do
      {:ok, line} ->
        size =
          case parse_size(line) do
            {:ok, n} -> n
            _ -> raise "invalid streaming chunk size"
          end

        if size == 0 do
          skip_file_trailers(input, 0)
          :ok
        else
          copy_bytes(input, output, size)
          expect_crlf(input)
          copy_unsigned_chunks(input, output)
        end

      :eof ->
        raise "truncated streaming body"
    end
  end

  # Like read_frame_line/1 but returns :eof on clean end-of-input instead
  # of raising (tolerates clients that omit the final CRLF/trailer block).
  defp read_frame_line_eof(input), do: read_frame_line_eof(input, <<>>)

  defp read_frame_line_eof(_input, acc) when byte_size(acc) > @header_line_limit do
    raise "streaming header line too long"
  end

  defp read_frame_line_eof(input, acc) do
    case :file.read(input, 1) do
      {:ok, "\r"} ->
        case :file.read(input, 1) do
          {:ok, "\n"} -> {:ok, acc}
          _ -> raise "bad streaming chunk framing"
        end

      {:ok, byte} ->
        read_frame_line_eof(input, acc <> byte)

      :eof when acc == <<>> ->
        :eof

      :eof ->
        raise "truncated streaming body"

      {:error, reason} ->
        raise "unreadable streaming body: #{inspect(reason)}"
    end
  end

  defp skip_file_trailers(_input, count) when count > 16 do
    raise "too many streaming trailers"
  end

  defp skip_file_trailers(input, count) do
    case read_frame_line_eof(input) do
      {:ok, ""} -> :ok
      {:ok, _} -> skip_file_trailers(input, count + 1)
      :eof -> :ok
    end
  end

  @doc """
  Replaces the temp file content with the decoded payload when the request
  uses streaming framing. Returns `:ok` or `{:error, reason}`.
  """
  @spec maybe_decode_file!(Plug.Conn.t(), String.t()) :: :ok
  def maybe_decode_file!(conn, tmp_path) do
    if streaming?(conn) do
      decode_file!(tmp_path)
    else
      :ok
    end
  end

  @doc """
  File-to-file variant of `decode/1`: reads framed chunks from `src` and
  writes the raw payload to a temp file, then atomically replaces `src`.
  All reads are bounded (`@copy_slice`), so memory stays flat regardless
  of payload size.
  """
  @spec decode_file!(String.t()) :: :ok
  def decode_file!(src) do
    dst = src <> ".streaming-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
    {:ok, input} = :file.open(src, [:read, :binary, :raw])

    try do
      {:ok, output} = :file.open(dst, [:write, :binary, :raw])

      try do
        copy_chunks(input, output)
        :file.close(output)
        :file.close(input)
        File.rename!(dst, src)
        :ok
      rescue
        e ->
          :file.close(output)
          File.rm(dst)
          reraise e, __STACKTRACE__
      end
    rescue
      e ->
        :file.close(input)
        reraise e, __STACKTRACE__
    end
  end

  @doc """
  Like `decode_file!/1`, but verifies every chunk signature against the
  HMAC chain before accepting its bytes. `context` comes from
  `Keeplix.S3.Auth.streaming_context/2` (seed signature, scope, key).
  Raises on missing/invalid signatures, truncation, or bad framing.
  """
  @spec verify_and_decode_file!(String.t(), map()) :: :ok
  def verify_and_decode_file!(
        src,
        %{signing_key: _, amz_date: _, scope: _, seed_signature: _} = ctx
      ) do
    dst = src <> ".streaming-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
    {:ok, input} = :file.open(src, [:read, :binary, :raw])

    try do
      {:ok, output} = :file.open(dst, [:write, :binary, :raw])

      try do
        copy_verified_chunks(input, output, ctx.seed_signature, ctx)
        :file.close(output)
        :file.close(input)
        File.rename!(dst, src)
        :ok
      rescue
        e ->
          :file.close(output)
          File.rm(dst)
          reraise e, __STACKTRACE__
      end
    rescue
      e ->
        :file.close(input)
        reraise e, __STACKTRACE__
    end
  end

  defp copy_verified_chunks(input, output, prev_signature, ctx) do
    {:ok, line} = read_frame_line(input)
    {size, ext_signature} = parse_signed_header!(line)
    chunk_hash = copy_chunk_hash(input, output, size)

    if size == 0 do
      expect_crlf_or_eof(input)
    else
      expect_crlf(input)
    end

    expected = chunk_signature(ctx, prev_signature, chunk_hash)

    unless signatures_match?(expected, ext_signature) do
      raise "streaming chunk signature mismatch"
    end

    if size == 0 do
      :ok
    else
      copy_verified_chunks(input, output, String.downcase(ext_signature), ctx)
    end
  end

  # Streams chunk bytes to the output while hashing (bounded slices);
  # returns the hex hash for the signature calculation.
  defp copy_chunk_hash(input, output, size) do
    hash = copy_chunk_hash(input, output, size, :crypto.hash_init(:sha256))
    :crypto.hash_final(hash) |> Base.encode16(case: :lower)
  end

  defp copy_chunk_hash(_input, _output, 0, hash), do: hash

  defp copy_chunk_hash(input, output, remaining, hash) do
    case :file.read(input, min(remaining, @copy_slice)) do
      {:ok, data} when byte_size(data) > 0 ->
        :ok = :file.write(output, data)

        copy_chunk_hash(
          input,
          output,
          remaining - byte_size(data),
          :crypto.hash_update(hash, data)
        )

      _ ->
        raise "truncated streaming body"
    end
  end

  defp parse_signed_header!(line) do
    case String.split(line, ";", parts: 2) do
      [size_part, ext] ->
        size =
          case parse_size(size_part) do
            {:ok, n} -> n
            _ -> raise "invalid streaming chunk size"
          end

        signature =
          ext
          |> String.split(";")
          |> Enum.find_value(fn part ->
            case String.split(String.trim(part), "=", parts: 2) do
              ["chunk-signature", sig] -> String.trim(sig)
              _ -> nil
            end
          end)

        if is_binary(signature) and signature != "" do
          {size, signature}
        else
          raise "streaming chunk without signature"
        end

      _ ->
        raise "streaming chunk without signature"
    end
  end

  defp chunk_signature(
         %{signing_key: key, amz_date: date, scope: scope},
         prev_signature,
         chunk_hash
       ) do
    string_to_sign =
      Enum.join(
        ["AWS4-HMAC-SHA256-PAYLOAD", date, scope, prev_signature, @empty_sha256, chunk_hash],
        "\n"
      )

    :crypto.mac(:hmac, :sha256, key, string_to_sign) |> Base.encode16(case: :lower)
  end

  defp signatures_match?(expected, actual) do
    normalized = if is_binary(actual), do: String.downcase(actual), else: ""

    byte_size(expected) == byte_size(normalized) and
      Plug.Crypto.secure_compare(expected, normalized)
  end

  defp copy_chunks(input, output) do
    case read_frame_line(input) do
      {:ok, line} ->
        size =
          case parse_size(line) do
            {:ok, n} -> n
            _ -> raise "invalid streaming chunk size"
          end

        if size == 0 do
          expect_crlf_or_eof(input)
          :ok
        else
          copy_bytes(input, output, size)
          expect_crlf(input)
          copy_chunks(input, output)
        end

      :eof ->
        raise "truncated streaming body"
    end
  end

  # Byte-by-byte: header lines are tiny, and block reads could swallow
  # framed payload bytes already consumed from the descriptor.
  defp read_frame_line(input), do: read_frame_line(input, <<>>)

  defp read_frame_line(_input, acc) when byte_size(acc) > @header_line_limit do
    raise "streaming header line too long"
  end

  defp read_frame_line(input, acc) do
    case :file.read(input, 1) do
      {:ok, "\r"} ->
        case :file.read(input, 1) do
          {:ok, "\n"} -> {:ok, acc}
          _ -> raise "bad streaming chunk framing"
        end

      {:ok, byte} ->
        read_frame_line(input, acc <> byte)

      :eof ->
        raise "truncated streaming body"

      {:error, reason} ->
        raise "unreadable streaming body: #{inspect(reason)}"
    end
  end

  defp copy_bytes(_input, _output, 0), do: :ok

  defp copy_bytes(input, output, remaining) do
    case :file.read(input, min(remaining, @copy_slice)) do
      {:ok, data} when byte_size(data) > 0 ->
        :ok = :file.write(output, data)
        copy_bytes(input, output, remaining - byte_size(data))

      _ ->
        raise "truncated streaming body"
    end
  end

  defp expect_crlf(input) do
    case :file.read(input, 2) do
      {:ok, "\r\n"} -> :ok
      _ -> raise "bad streaming chunk framing"
    end
  end

  defp expect_crlf_or_eof(input) do
    case :file.read(input, 2) do
      {:ok, "\r\n"} -> :ok
      :eof -> :ok
      _ -> raise "bad streaming chunk framing"
    end
  end
end
