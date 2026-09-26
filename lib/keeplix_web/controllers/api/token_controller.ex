defmodule KeeplixWeb.Api.TokenController do
  @moduledoc """
  Management API: personal access tokens of a user (admin only).
  The plain token is returned only at creation time.
  """
  use KeeplixWeb, :controller

  alias Keeplix.{Accounts, Audit, RateLimit}

  action_fallback KeeplixWeb.Api.FallbackController

  def index(conn, %{"user_id" => user_id}) do
    with %Accounts.User{} = user <- Accounts.get_user(user_id) do
      json(conn, %{tokens: Enum.map(Accounts.list_api_tokens(user.id), &render_token/1)})
    else
      nil -> {:error, :not_found}
    end
  end

  def create(conn, %{"user_id" => user_id} = params) do
    with %Accounts.User{} = user <- Accounts.get_user(user_id),
         {:ok, expires_at} <- parse_expiry(params["expires_in_days"]),
         {:ok, record, plain} <-
           Accounts.create_api_token(user, params["name"] || "api", expires_at: expires_at) do
      audit(conn, "api.token.create", record.prefix, %{user_id: user.id})

      conn
      |> put_status(201)
      |> json(%{token: Map.put(render_token(record), :token, plain)})
    else
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, {:invalid, changeset}}
    end
  end

  def delete(conn, %{"user_id" => user_id, "id" => id}) do
    with %Accounts.User{} = user <- Accounts.get_user(user_id),
         {token_id, ""} <- Integer.parse(to_string(id)),
         :ok <- Accounts.revoke_api_token(user, token_id) do
      audit(conn, "api.token.revoke", to_string(token_id), %{user_id: user.id})
      send_resp(conn, 204, "")
    else
      _ -> {:error, :not_found}
    end
  end

  defp parse_expiry(nil), do: {:ok, nil}
  defp parse_expiry(""), do: {:ok, nil}

  defp parse_expiry(days) do
    case Integer.parse(to_string(days)) do
      {n, ""} when n > 0 ->
        {:ok,
         DateTime.utc_now() |> DateTime.add(n * 86_400, :second) |> DateTime.truncate(:second)}

      _ ->
        {:error, {:invalid, expiry_changeset()}}
    end
  end

  defp expiry_changeset do
    %Ecto.Changeset{} |> Ecto.Changeset.add_error(:expires_in_days, "must be a positive integer")
  end

  defp render_token(t) do
    %{
      id: t.id,
      name: t.name,
      prefix: t.prefix,
      last_used_at: t.last_used_at,
      expires_at: t.expires_at,
      inserted_at: t.inserted_at
    }
  end

  defp audit(conn, action, target, details) do
    Audit.log(
      conn.assigns.api_user,
      action,
      target,
      Map.put(details, :ip, RateLimit.client_ip(conn))
    )
  end
end
