defmodule Keeplix.LoginTokens do
  @moduledoc """
  Single-use login completion tokens.

  LiveViews cannot write the Plug session, so a successful second-factor
  ceremony ends with a redirect to a controller endpoint. The token
  (256-bit, 5-minute expiry) proves the ceremony happened; the endpoint
  additionally requires the matching pending login in the session, so a
  stolen token alone is useless.
  """
  use GenServer

  @table __MODULE__
  @ttl_seconds 5 * 60
  @sweep_interval 60_000

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
    now = System.system_time(:second)

    stale =
      :ets.foldl(fn {t, {_, exp}}, acc -> if exp <= now, do: [t | acc], else: acc end, [], @table)

    Enum.each(stale, &:ets.delete(@table, &1))
    Process.send_after(self(), :sweep, @sweep_interval)
    {:noreply, state}
  end

  @spec issue(integer(), integer()) :: String.t()
  def issue(user_id, ttl_seconds \\ @ttl_seconds) when is_integer(user_id) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    :ets.insert(@table, {token, {user_id, System.system_time(:second) + ttl_seconds}})
    token
  end

  @spec consume(String.t() | term()) :: {:ok, integer()} | {:error, :invalid | :expired}
  def consume(token) when is_binary(token) do
    case :ets.lookup(@table, token) do
      [{_, {user_id, exp}}] ->
        :ets.delete(@table, token)

        if exp > System.system_time(:second) do
          {:ok, user_id}
        else
          {:error, :expired}
        end

      [] ->
        {:error, :invalid}
    end
  end

  def consume(_), do: {:error, :invalid}
end
