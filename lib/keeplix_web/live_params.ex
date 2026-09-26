defmodule KeeplixWeb.LiveParams do
  @moduledoc """
  Defensive parsing of LiveView event params.

  Browsers send strings, but crafted events can carry any term —
  handlers must never crash on them.
  """

  @spec id(term()) :: {:ok, pos_integer()} | :error
  def id(value) when is_integer(value) and value > 0, do: {:ok, value}

  def id(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  def id(_), do: :error
end
