defmodule KeeplixWeb.Api.GroupController do
  @moduledoc """
  Management API: groups and memberships (admin only, HTTP Basic).
  """
  use KeeplixWeb, :controller

  alias Keeplix.{Accounts, Audit, RateLimit}

  action_fallback KeeplixWeb.Api.FallbackController

  def index(conn, _params) do
    json(conn, %{groups: Enum.map(Accounts.list_groups(), &render_group/1)})
  end

  def show(conn, %{"id" => id}) do
    with %Accounts.Group{} = group <- Accounts.get_group(id) do
      json(conn, %{group: render_group(group)})
    else
      nil -> {:error, :not_found}
    end
  end

  def create(conn, params) do
    with {:ok, group} <- Accounts.create_group(params) do
      audit(conn, "api.group.create", group.name, %{id: group.id})
      conn |> put_status(201) |> json(%{group: render_group(group)})
    else
      {:error, changeset} -> {:error, {:invalid, changeset}}
    end
  end

  def update(conn, %{"id" => id} = params) do
    with %Accounts.Group{} = group <- Accounts.get_group(id),
         {:ok, group} <- Accounts.update_group(group, Map.delete(params, "id")) do
      audit(conn, "api.group.update", group.name, %{id: group.id})
      json(conn, %{group: render_group(group)})
    else
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, {:invalid, changeset}}
    end
  end

  def delete(conn, %{"id" => id}) do
    with %Accounts.Group{} = group <- Accounts.get_group(id),
         {:ok, _} <- Accounts.delete_group(group) do
      audit(conn, "api.group.delete", group.name, %{id: group.id})
      send_resp(conn, 204, "")
    else
      nil -> {:error, :not_found}
      {:error, _} -> {:error, :conflict}
    end
  end

  def add_member(conn, %{"id" => id, "user_id" => user_id}) do
    with %Accounts.Group{} = group <- Accounts.get_group(id),
         %Accounts.User{} = user <- Accounts.get_user(user_id),
         {:ok, _} <- Accounts.add_user_to_group(user, group) do
      audit(conn, "api.group.add_member", group.name, %{user_id: user.id})
      json(conn, %{group: render_group(Accounts.get_group!(group.id))})
    else
      nil -> {:error, :not_found}
      _ -> {:error, :conflict}
    end
  end

  def remove_member(conn, %{"id" => id, "user_id" => user_id}) do
    with %Accounts.Group{} = group <- Accounts.get_group(id),
         %Accounts.User{} = user <- Accounts.get_user(user_id),
         :ok <- Accounts.remove_user_from_group(user, group) do
      audit(conn, "api.group.remove_member", group.name, %{user_id: user.id})
      send_resp(conn, 204, "")
    else
      nil -> {:error, :not_found}
      _ -> {:error, :conflict}
    end
  end

  defp render_group(g) do
    members =
      case g do
        %{users: users} when is_list(users) -> Enum.map(users, & &1.id)
        _ -> nil
      end

    %{id: g.id, name: g.name, description: g.description, member_ids: members}
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
