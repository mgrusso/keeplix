defmodule KeeplixWeb.Api.FallbackController do
  @moduledoc """
  Maps `{:error, reason}` tuples from API controllers to JSON responses.
  """
  use KeeplixWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(404)
    |> json(%{error: %{code: "not_found", message: "Resource not found"}})
  end

  def call(conn, {:error, :forbidden_self}) do
    conn
    |> put_status(403)
    |> json(%{
      error: %{code: "forbidden", message: "You cannot change your own account this way"}
    })
  end

  def call(conn, {:error, :forbidden_last_admin}) do
    conn
    |> put_status(403)
    |> json(%{
      error: %{code: "forbidden", message: "You cannot remove or disable the last admin"}
    })
  end

  def call(conn, {:error, :conflict}) do
    conn
    |> put_status(409)
    |> json(%{error: %{code: "conflict", message: "Resource cannot be removed"}})
  end

  def call(conn, {:error, {:invalid, changeset}}) do
    conn
    |> put_status(422)
    |> json(%{
      error: %{code: "invalid", message: "Validation failed", details: errors(changeset)}
    })
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
