defmodule KeeplixWeb.Api.UserController do
  @moduledoc """
  Management API: users (admin only, HTTP Basic).
  """
  use KeeplixWeb, :controller

  alias Keeplix.{Accounts, Audit, RateLimit}

  action_fallback KeeplixWeb.Api.FallbackController

  def index(conn, _params) do
    json(conn, %{users: Enum.map(Accounts.list_users(), &render_user/1)})
  end

  def show(conn, %{"id" => id}) do
    with %Accounts.User{} = user <- Accounts.get_user(id) do
      json(conn, %{user: render_user(user)})
    else
      nil -> {:error, :not_found}
    end
  end

  def create(conn, params) do
    with {:ok, user} <- Accounts.create_user(params) do
      audit(conn, "api.user.create", user.username, %{id: user.id})
      conn |> put_status(201) |> json(%{user: render_user(user)})
    else
      {:error, changeset} -> {:error, {:invalid, changeset}}
    end
  end

  def update(conn, %{"id" => id} = params) do
    me = conn.assigns.api_user

    with %Accounts.User{} = user <- Accounts.get_user(id),
         :ok <- guard_admin_change(me, user, params),
         {:ok, user} <- Accounts.update_user(user, Map.delete(params, "id")) do
      audit(conn, "api.user.update", user.username, %{id: user.id})
      json(conn, %{user: render_user(user)})
    else
      nil -> {:error, :not_found}
      {:error, :self_protection} -> {:error, :forbidden_self}
      {:error, :last_admin} -> {:error, :forbidden_last_admin}
      {:error, changeset} -> {:error, {:invalid, changeset}}
    end
  end

  def delete(conn, %{"id" => id}) do
    me = conn.assigns.api_user

    with %Accounts.User{} = user <- Accounts.get_user(id),
         :ok <- guard_admin_delete(me, user),
         {:ok, _} <- Accounts.delete_user(user) do
      audit(conn, "api.user.delete", user.username, %{id: user.id})
      send_resp(conn, 204, "")
    else
      nil -> {:error, :not_found}
      {:error, :self_protection} -> {:error, :forbidden_self}
      {:error, :last_admin} -> {:error, :forbidden_last_admin}
      {:error, _} -> {:error, :conflict}
    end
  end

  # Mirrors the Admin.UserLive guards: no self-deletion, no removing or
  # disabling the last admin.
  defp guard_admin_delete(%{id: me_id}, %{id: id}) when me_id == id,
    do: {:error, :self_protection}

  defp guard_admin_delete(_me, %{role: "admin"}) do
    if Accounts.count_admins() <= 1, do: {:error, :last_admin}, else: :ok
  end

  defp guard_admin_delete(_me, _user), do: :ok

  defp guard_admin_change(%{id: me_id}, %{id: id} = user, params) do
    demote? = Map.get(params, "role") == "user"
    suspend? = Map.get(params, "is_active") == false

    cond do
      user.role == "admin" and demote? and me_id == id ->
        {:error, :self_protection}

      user.role == "admin" and demote? and Accounts.count_admins() <= 1 ->
        {:error, :last_admin}

      user.role == "admin" and suspend? and Accounts.count_admins() <= 1 ->
        {:error, :last_admin}

      true ->
        :ok
    end
  end

  defp render_user(u) do
    %{id: u.id, username: u.username, role: u.role, is_active: u.is_active, email: u.email}
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
