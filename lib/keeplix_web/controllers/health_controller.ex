defmodule KeeplixWeb.HealthController do
  @moduledoc """
  Unauthenticated liveness/readiness probe for load balancers and
  container orchestration. Checks database reachability.
  """
  use KeeplixWeb, :controller

  @spec check(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def check(conn, _params) do
    case Ecto.Adapters.SQL.query(Keeplix.Repo, "SELECT 1", []) do
      {:ok, _} -> json(conn, %{status: "ok"})
      _ -> conn |> put_status(503) |> json(%{status: "unavailable"})
    end
  end
end
