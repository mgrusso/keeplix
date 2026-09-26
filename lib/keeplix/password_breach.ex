defmodule Keeplix.PasswordBreach do
  @moduledoc """
  HaveIBeenPwned k-anonymity breach check for new passwords.

  Only the first 5 hex chars of the SHA-1 reach the API; the full hash
  never leaves the server. Unreachable API fails OPEN (availability
  first, logged). Disable entirely with:

      config :keeplix, Keeplix.PasswordBreach, enabled: false

  Tests inject a stub via `:http_client`.
  """
  require Logger

  @range_url "https://api.pwnedpasswords.com/range/"

  @spec count(String.t(), (String.t() -> {:ok, map()} | {:error, term()})) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count(password, http_client \\ &default_client/1) when is_binary(password) do
    digest = :crypto.hash(:sha, password) |> Base.encode16(case: :upper)
    {prefix, suffix} = String.split_at(digest, 5)

    with {:ok, %{status: 200, body: body}} <- http_client.(@range_url <> prefix) do
      {:ok, find_count(to_string(body), suffix)}
    end
  end

  @spec breached?(String.t()) :: boolean()
  def breached?(password) when is_binary(password) do
    if enabled?() do
      client =
        (Application.get_env(:keeplix, __MODULE__, []) || [])[:http_client] || (&default_client/1)

      case count(password, client) do
        {:ok, n} when n > 0 ->
          true

        {:error, reason} ->
          Logger.warning("breach check unavailable: #{inspect(reason)}")
          false

        _ ->
          false
      end
    else
      false
    end
  end

  def breached?(_), do: false

  @spec enabled?() :: boolean()
  def enabled? do
    (Application.get_env(:keeplix, __MODULE__, []) || [])[:enabled] != false
  end

  defp default_client(url) do
    Req.get(url, receive_timeout: 5_000, retry: false)
  end

  defp find_count(body, suffix) do
    body
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":") do
        [^suffix, count] ->
          case Integer.parse(String.trim(count)) do
            {n, ""} -> n
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end
end
