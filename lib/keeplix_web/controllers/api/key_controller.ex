defmodule KeeplixWeb.Api.KeyController do
  @moduledoc """
  Management API: access keys of a user (admin only, HTTP Basic).
  The secret is returned only at creation time.
  """
  use KeeplixWeb, :controller

  alias Keeplix.{Accounts, Audit, RateLimit}

  action_fallback KeeplixWeb.Api.FallbackController

  def index(conn, %{"user_id" => user_id}) do
    with %Accounts.User{} = user <- Accounts.get_user(user_id) do
      keys = Accounts.list_keys_for_user(user.id) |> Enum.map(&render_key/1)
      json(conn, %{keys: keys})
    else
      nil -> {:error, :not_found}
    end
  end

  def create(conn, %{"user_id" => user_id} = params) do
    with %Accounts.User{} = user <- Accounts.get_user(user_id),
         {:ok, _record, creds} <- Accounts.create_access_key(user, params["description"]) do
      audit(conn, "api.key.create", creds.access_key_id, %{user_id: user.id})

      conn
      |> put_status(201)
      |> json(%{
        key: Map.merge(render_key_by_id(creds.access_key_id, user), %{secret: creds.secret})
      })
    else
      nil -> {:error, :not_found}
      {:error, _} -> {:error, :conflict}
    end
  end

  def delete(conn, %{"user_id" => user_id, "id" => id}) do
    with %Accounts.User{} = user <- Accounts.get_user(user_id),
         {key_id, ""} <- Integer.parse(to_string(id)),
         %Accounts.AccessKey{user_id: key_uid} = key <- Accounts.get_access_key(key_id),
         true <- key_uid == user.id,
         {:ok, _} <- Accounts.delete_access_key(key.id) do
      audit(conn, "api.key.delete", key.access_key_id, %{user_id: user.id})
      send_resp(conn, 204, "")
    else
      _ -> {:error, :not_found}
    end
  end

  defp render_key(k) do
    %{id: k.id, access_key_id: k.access_key_id, description: k.description, active: k.active}
  end

  defp render_key_by_id(access_key_id, user) do
    user.id
    |> Accounts.list_keys_for_user()
    |> Enum.find(&(&1.access_key_id == access_key_id))
    |> case do
      nil -> %{access_key_id: access_key_id}
      key -> render_key(key)
    end
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
