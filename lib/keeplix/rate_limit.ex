defmodule Keeplix.RateLimit do
  @moduledoc """
  Fixed-window failure tracking with temporary blocks (brute-force protection).

  Backed by an ETS table owned by this GenServer, swept every minute.
  Buckets:

  - `:login_ip` / `:login_user` — password login attempts
  - `:s3_ip` — failed S3 authentications per client IP
  - `:api_ip` — failed management API authentications per client IP

  Counters expire via their time window only; successes never reset them
  (attacks must not be able to interleave innocent requests).

  Behind a reverse proxy every client shares the proxy's address, so
  `X-Forwarded-For` is honored — but only when the direct peer is a
  configured trusted proxy (default: loopback). Never trust the header
  from untrusted peers (spoofable):

      config :keeplix, Keeplix.RateLimit,
        trusted_proxies: ["127.0.0.1", "::1", "10.0.0.0/8"]

  Limits can be overridden per bucket via app env, e.g. in tests:

      config :keeplix, Keeplix.RateLimit, s3_ip: [max_attempts: 3]
  """
  use GenServer

  @table __MODULE__
  @sweep_interval 60_000

  @defaults %{
    login_ip: [max_attempts: 10, window_ms: 5 * 60 * 1000, block_ms: 10 * 60 * 1000],
    login_user: [max_attempts: 10, window_ms: 5 * 60 * 1000, block_ms: 10 * 60 * 1000],
    s3_ip: [max_attempts: 100, window_ms: 5 * 60 * 1000, block_ms: 5 * 60 * 1000],
    api_ip: [max_attempts: 30, window_ms: 5 * 60 * 1000, block_ms: 10 * 60 * 1000]
  }

  # ---------- lifecycle ----------

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    Process.send_after(self(), :sweep, @sweep_interval)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, @sweep_interval)
    {:noreply, state}
  end

  # ---------- API ----------

  @spec check(atom(), String.t(), integer()) :: :ok | :blocked
  def check(bucket, key, now \\ now_ms()) do
    _ = limits(bucket)

    case :ets.lookup(@table, {bucket, key}) do
      [{_, {_count, _start, blocked_until}}] when blocked_until > now -> :blocked
      _ -> :ok
    end
  end

  @spec track_failure(atom(), String.t(), integer()) :: :ok
  def track_failure(bucket, key, now \\ now_ms()) do
    [max_attempts: max, window_ms: window, block_ms: block] = limits(bucket)

    {count, start, blocked} =
      case :ets.lookup(@table, {bucket, key}) do
        [{_, {c, s, b}}] -> {c, s, b}
        [] -> {0, now, 0}
      end

    {count, start} =
      if blocked <= now and now - start > window, do: {0, now}, else: {count, start}

    count = count + 1
    blocked = if count >= max, do: now + block, else: blocked
    :ets.insert(@table, {{bucket, key}, {count, start, blocked}})
    :ok
  end

  @spec reset(atom(), String.t()) :: :ok
  def reset(bucket, key) do
    _ = limits(bucket)
    :ets.delete(@table, {bucket, key})
    :ok
  end

  @spec reset_all() :: :ok
  def reset_all do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Removes entries whose window and block (if any) both expired.
  Returns the removed count.
  """
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now \\ now_ms()) do
    stale =
      :ets.foldl(
        fn {{bucket, key}, {_count, start, blocked}}, acc ->
          window = limits(bucket)[:window_ms]

          if now - start > window and now >= blocked do
            [{bucket, key} | acc]
          else
            acc
          end
        end,
        [],
        @table
      )

    Enum.each(stale, &:ets.delete(@table, &1))
    length(stale)
  end

  @doc """
  Best-effort client IP for a conn.

  Honors `X-Forwarded-For` only when the direct peer is a trusted proxy
  (loopback by default, configurable via `:trusted_proxies`). Behind a
  reverse proxy this is the only way to tell clients apart; from
  untrusted peers the header is ignored (spoof-proof).
  """
  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(conn) do
    peer = conn.remote_ip

    if trusted_peer?(peer) do
      forwarded_client(conn, peer) || format_ip(peer)
    else
      format_ip(peer)
    end
  end

  # ---------- internals ----------

  # Right-to-left: the entry appended by the closest trusted proxy is the
  # client; anything further left may be spoofed caller input.
  defp forwarded_client(conn, _peer) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [header | _] ->
        header
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reverse()
        |> Enum.find_value(fn entry ->
          if valid_ip?(entry) and not trusted_ip?(entry), do: entry
        end)

      [] ->
        nil
    end
  end

  defp format_ip(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      addr when is_list(addr) -> to_string(addr)
      _ -> "unknown"
    end
  end

  defp format_ip(_), do: "unknown"

  defp valid_ip?(entry) when is_binary(entry) do
    match?({:ok, _}, :inet.parse_address(String.to_charlist(entry)))
  end

  defp valid_ip?(_), do: false

  defp trusted_peer?(ip) when is_tuple(ip) do
    Enum.any?(trusted_proxies(), &ip_in_range?(ip, &1))
  end

  defp trusted_peer?(_), do: false

  defp trusted_ip?(entry) when is_binary(entry) do
    case :inet.parse_address(String.to_charlist(entry)) do
      {:ok, ip} -> trusted_peer?(ip)
      _ -> false
    end
  end

  defp trusted_proxies do
    (Application.get_env(:keeplix, __MODULE__, []) || [])[:trusted_proxies] ||
      ["127.0.0.1", "::1"]
  end

  defp ip_in_range?(ip, cidr) when is_binary(cidr) do
    case String.split(cidr, "/", parts: 2) do
      [net, bits] when tuple_size(ip) == 4 ->
        with {:ok, net_ip} when tuple_size(net_ip) == 4 <-
               :inet.parse_address(String.to_charlist(net)),
             {n, ""} <- Integer.parse(bits),
             true <- n in 0..32 do
          masked(ip_to_int(ip), n, 32) == masked(ip_to_int(net_ip), n, 32)
        else
          _ -> false
        end

      [single] ->
        case :inet.parse_address(String.to_charlist(single)) do
          {:ok, ^ip} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp ip_to_int({a, b, c, d}), do: a * 16_777_216 + b * 65_536 + c * 256 + d

  defp masked(_int, 0, _bits), do: 0
  defp masked(int, n, bits), do: Bitwise.band(int, Bitwise.bsl(0xFFFFFFFF, bits - n))

  defp limits(bucket) do
    defaults = Map.fetch!(@defaults, bucket)
    overrides = (Application.get_env(:keeplix, __MODULE__, []) || []) |> Keyword.get(bucket, [])
    Keyword.merge(defaults, overrides)
  end

  defp now_ms, do: System.system_time(:millisecond)
end
