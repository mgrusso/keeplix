defmodule Keeplix.Replication do
  @moduledoc """
  Extension point for future server sync.

  Status v0.1: **no replication active**. This module only defines the
  interface and configuration so push and/or pull
  replication can be added later (e.g. for tiered protection /
  graded protection zones across sites).

  Planned modes:
  - `:push` - this node pushes changes to target nodes
  - `:pull` - this node pulls changes from source nodes
  - `:bidirectional` - both (only for equivalent zones)
  - `:none` - no replication (default)

  Konfiguration (config/runtime.exs bzw. Umgebungsvariablen):

      config :keeplix, Keeplix.Replication,
        mode: :none,
        peers: [],
        interval_ms: 60_000

  Each peer definition should later contain:
  `%{name: "standort-b", endpoint: "https://...", access_key: "...", secret: "...", direction: :push | :pull, buckets: ["*"]}`
  """

  @callback push(bucket :: String.t(), key :: String.t(), payload :: map()) ::
              :ok | {:error, term()}
  @callback pull(peer :: map(), since :: DateTime.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @spec mode() :: atom()
  def mode do
    Application.get_env(:keeplix, __MODULE__, []) |> Keyword.get(:mode, :none)
  end

  @spec enabled?() :: boolean()
  def enabled?, do: mode() != :none

  @spec peers() :: [map()]
  def peers do
    Application.get_env(:keeplix, __MODULE__, []) |> Keyword.get(:peers, [])
  end

  @doc """
  Placeholder: currently always returns `{:error, :not_configured}` until
  an adapter is configured. Deliberately no background process in v0.1.
  """
  @spec push(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def push(_bucket, _key, _payload), do: {:error, :not_configured}
  @spec pull(map(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def pull(_peer, _since), do: {:error, :not_configured}

  @spec status() :: %{mode: atom(), enabled: boolean(), peers: [map()], note: String.t()}
  def status do
    %{
      mode: mode(),
      enabled: enabled?(),
      peers: peers(),
      note: "Replication disabled in v0.1 (interface reserved)"
    }
  end
end
