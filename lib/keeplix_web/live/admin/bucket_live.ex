defmodule KeeplixWeb.Admin.BucketLive do
  use KeeplixWeb, :live_view

  alias Keeplix.{Buckets, Accounts}
  alias Keeplix.Audit
  alias KeeplixWeb.LiveParams

  def mount(_params, session, socket) do
    user = get_user(session)

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:all_users, Accounts.list_users())
     |> assign(:all_groups, Accounts.list_groups())
     |> assign(:selected_bucket, nil)
     |> assign(:usage_bytes, nil)
     |> assign(:grants, [])
     |> stream(:buckets, Buckets.list_buckets())}
  end

  defp get_user(%{"user_id" => id}), do: Accounts.get_user(id)
  defp get_user(_), do: nil

  def handle_event("delete", %{"id" => raw}, socket) do
    with {:ok, id} <- LiveParams.id(raw),
         %Buckets.Bucket{} = b <- Buckets.get_bucket_by_id(id),
         :ok <- Buckets.delete_bucket(b) do
      Audit.log(socket.assigns.current_user, "bucket.delete", b.name, %{})

      {:noreply,
       socket
       |> stream_delete(:buckets, b)
       |> assign(:selected_bucket, nil)
       |> assign(:grants, [])
       |> put_flash(:info, "Bucket deleted.")}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Failed to delete.")}
    end
  end

  def handle_event("select", %{"id" => raw}, socket) do
    with {:ok, id} <- LiveParams.id(raw),
         %Buckets.Bucket{} = b <- Buckets.get_bucket_by_id(id) do
      %{bytes: bytes} = Buckets.usage(b)

      {:noreply,
       socket
       |> assign(:selected_bucket, b)
       |> assign(:grants, Buckets.list_grants(b.id))
       |> assign(:usage_bytes, bytes)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Bucket not found.")}
    end
  end

  def handle_event("grant-user", %{"user_id" => raw_uid, "permission" => perm}, socket) do
    with %Buckets.Bucket{} = b <- socket.assigns.selected_bucket,
         {:ok, uid} <- LiveParams.id(raw_uid),
         {:ok, _} <- Buckets.grant_permission(b.id, perm, user_id: uid, group_id: nil) do
      Audit.log(socket.assigns.current_user, "bucket.grant", b.name, %{
        permission: perm,
        user_id: uid
      })

      {:noreply, assign(socket, :grants, Buckets.list_grants(b.id))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid grant.")}
    end
  end

  def handle_event("grant-group", %{"group_id" => raw_gid, "permission" => perm}, socket) do
    with %Buckets.Bucket{} = b <- socket.assigns.selected_bucket,
         {:ok, gid} <- LiveParams.id(raw_gid),
         {:ok, _} <- Buckets.grant_permission(b.id, perm, group_id: gid, user_id: nil) do
      Audit.log(socket.assigns.current_user, "bucket.grant", b.name, %{
        permission: perm,
        group_id: gid
      })

      {:noreply, assign(socket, :grants, Buckets.list_grants(b.id))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid grant.")}
    end
  end

  def handle_event("revoke", %{"id" => raw}, socket) do
    with {:ok, gid} <- LiveParams.id(raw),
         {:ok, _} <- Buckets.revoke_grant(gid) do
      b = socket.assigns.selected_bucket
      Audit.log(socket.assigns.current_user, "bucket.revoke", b && b.name, %{grant_id: gid})
      {:noreply, assign(socket, :grants, Buckets.list_grants(b.id))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Grant not found.")}
    end
  end

  def handle_event("save-quota", %{"quota_mb" => raw}, socket) do
    with %Buckets.Bucket{} = b <- socket.assigns.selected_bucket,
         {:ok, quota} <- parse_quota(raw),
         {:ok, updated} <- Buckets.update_bucket(b, %{quota_bytes: quota}) do
      Audit.log(socket.assigns.current_user, "bucket.quota", b.name, %{quota_bytes: quota})

      {:noreply,
       socket
       |> assign(:selected_bucket, updated)
       |> put_flash(:info, "Quota updated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid quota (megabytes, empty = unlimited).")}
    end
  end

  def handle_event("save-versioning", %{"versioning" => mode}, socket) do
    with %Buckets.Bucket{} = b <- socket.assigns.selected_bucket,
         {:ok, updated} <- Buckets.set_versioning(b, mode) do
      Audit.log(socket.assigns.current_user, "bucket.versioning", b.name, %{versioning: mode})

      {:noreply,
       socket
       |> assign(:selected_bucket, updated)
       |> put_flash(:info, "Versioning updated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid versioning transition.")}
    end
  end

  def handle_event("save-acl", %{"acl" => acl}, socket) do
    with %Buckets.Bucket{} = b <- socket.assigns.selected_bucket,
         true <- acl in ["private", "public-read"],
         {:ok, updated} <- Buckets.update_bucket(b, %{acl: acl}) do
      Audit.log(socket.assigns.current_user, "bucket.acl", b.name, %{acl: acl})

      {:noreply,
       socket
       |> assign(:selected_bucket, updated)
       |> put_flash(:info, "Bucket access updated.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid access level.")}
    end
  end

  # Megabytes as typed in the form; empty means unlimited (NULL).
  # Megabytes as typed in the form; empty means unlimited (NULL).
  defp parse_quota(raw) do
    case String.trim(to_string(raw)) do
      "" ->
        {:ok, nil}

      s ->
        case Integer.parse(s) do
          {mb, ""} when mb > 0 -> {:ok, mb * 1_048_576}
          _ -> :error
        end
    end
  end

  defp format_bytes(nil), do: "—"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <h1 class="text-3xl font-bold text-slate-900 dark:text-slate-100">All buckets</h1>
      <p class="mt-1 text-sm font-medium text-slate-700 dark:text-slate-300">
        Delete buckets and manage grants (read / write / admin) for users and groups.
      </p>

      <div class="mt-5 grid gap-5 md:grid-cols-2">
        <div class="rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 shadow-sm">
          <h2 class="font-bold text-slate-900 dark:text-slate-100">Buckets</h2>
          <div id="buckets" phx-update="stream" class="mt-3 space-y-2">
            <div
              id="no-buckets"
              class="hidden only:block rounded-lg bg-slate-50 dark:bg-slate-800 p-4 text-sm font-medium text-slate-700 dark:text-slate-300"
            >
              No buckets yet.
            </div>
            <div
              :for={{id, b} <- @streams.buckets}
              id={id}
              class="flex items-center gap-2 rounded-lg border border-slate-200 dark:border-slate-700 px-3 py-2.5"
            >
              <span class="font-mono text-sm font-bold text-slate-900 dark:text-slate-100">{b.name}</span>
              <button
                phx-click="select"
                phx-value-id={b.id}
                class="ml-auto rounded-lg border border-slate-300 dark:border-slate-700 px-3 py-1.5 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
              >Grants</button>
              <button
                phx-click="delete"
                phx-value-id={b.id}
                class="rounded-lg border border-red-300 dark:border-red-800 px-3 py-1.5 text-sm font-semibold text-red-700 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950"
                data-confirm="Really delete the bucket with all files?"
              >Delete</button>
            </div>
          </div>
        </div>
        <div class="rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 shadow-sm">
          <%= if @selected_bucket do %>
            <h2 class="font-bold text-slate-900 dark:text-slate-100">
              Grants: <span class="font-mono">{@selected_bucket.name}</span>
            </h2>
            <p class="mt-1 text-sm font-medium text-slate-700 dark:text-slate-300">
              Usage: {format_bytes(@usage_bytes)} · Quota: {if @selected_bucket.quota_bytes,
                do: format_bytes(@selected_bucket.quota_bytes),
                else: "unlimited"} · Versioning: {@selected_bucket.versioning} · Access: {@selected_bucket.acl ||
                "private"}
            </p>
            <form
              phx-submit="save-acl"
              class="mt-3 flex flex-wrap items-end gap-2 rounded-lg border border-slate-200 dark:border-slate-700 p-3"
            >
              <div>
                <label
                  for="acl"
                  class="mb-1 block text-xs font-bold text-slate-900 dark:text-slate-100"
                >
                  Access (public-read: anonymous downloads, no listing)
                </label>
                <select
                  id="acl"
                  name="acl"
                  class="h-10 rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-2 text-sm font-medium text-slate-900 dark:text-slate-100"
                >
                  <%= for mode <- ["private", "public-read"] do %>
                    <option value={mode} selected={(@selected_bucket.acl || "private") == mode}>
                      {mode}
                    </option>
                  <% end %>
                </select>
              </div>
              <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">Save access</button>
            </form>
            <form
              phx-submit="save-versioning"
              class="mt-3 flex flex-wrap items-end gap-2 rounded-lg border border-slate-200 dark:border-slate-700 p-3"
            >
              <div>
                <label
                  for="versioning"
                  class="mb-1 block text-xs font-bold text-slate-900 dark:text-slate-100"
                >
                  Versioning (off → enabled → suspended)
                </label>
                <select
                  id="versioning"
                  name="versioning"
                  class="h-10 rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-2 text-sm font-medium text-slate-900 dark:text-slate-100"
                >
                  <%= for mode <- ["off", "enabled", "suspended"] do %>
                    <option value={mode} selected={@selected_bucket.versioning == mode}>
                      {mode}
                    </option>
                  <% end %>
                </select>
              </div>
              <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">Save versioning</button>
            </form>
            <form
              phx-submit="save-quota"
              class="mt-3 flex flex-wrap items-end gap-2 rounded-lg border border-slate-200 dark:border-slate-700 p-3"
            >
              <div>
                <label
                  for="quota-mb"
                  class="mb-1 block text-xs font-bold text-slate-900 dark:text-slate-100"
                >
                  Quota (MB, empty = unlimited)
                </label>
                <input
                  id="quota-mb"
                  name="quota_mb"
                  inputmode="numeric"
                  placeholder="e.g. 1024"
                  value={
                    if @selected_bucket.quota_bytes,
                      do: div(@selected_bucket.quota_bytes, 1_048_576),
                      else: ""
                  }
                  class="h-10 w-40 rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm text-slate-900 dark:text-slate-100"
                />
              </div>
              <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">Save quota</button>
            </form>
            <ul class="mt-3 space-y-2 text-sm">
              <%= for g <- @grants do %>
                <li class="flex flex-wrap items-center gap-2 rounded-lg border border-slate-200 dark:border-slate-700 px-3 py-2">
                  <span class="font-semibold text-slate-900 dark:text-slate-100">{if g.user,
                    do: "User: " <> g.user.username,
                    else: "Group: " <> g.group.name}</span>
                  <span class="rounded-full bg-slate-100 dark:bg-slate-800 px-2.5 py-0.5 text-xs font-bold text-slate-900 dark:text-slate-100">{g.permission}</span>
                  <button
                    phx-click="revoke"
                    phx-value-id={g.id}
                    class="ml-auto font-semibold text-red-700 dark:text-red-400 hover:underline"
                  >Revoke</button>
                </li>
              <% end %>
            </ul>
            <%= if @grants == [] do %>
              <p class="mt-2 text-sm font-medium text-slate-700 dark:text-slate-300">
                No grants yet – only the owner and admins have access.
              </p>
            <% end %>
            <form
              phx-submit="grant-user"
              class="mt-4 flex flex-wrap items-end gap-2 border-t border-slate-200 dark:border-slate-700 pt-4"
            >
              <div>
                <label class="mb-1 block text-xs font-bold text-slate-900 dark:text-slate-100">User</label>
                <select
                  name="user_id"
                  class="h-10 rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-2 text-sm font-medium text-slate-900 dark:text-slate-100"
                >
                  <%= for u <- @all_users do %>
                    <option value={u.id}>{u.username}</option>
                  <% end %>
                </select>
              </div>
              <div>
                <label class="mb-1 block text-xs font-bold text-slate-900 dark:text-slate-100">Permission</label>
                <select
                  name="permission"
                  class="h-10 rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-2 text-sm font-medium text-slate-900 dark:text-slate-100"
                >
                  <option value="read">read</option><option value="write">write</option><option value="admin">
                    admin
                  </option>
                </select>
              </div>
              <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">Grant</button>
            </form>
            <form phx-submit="grant-group" class="mt-3 flex flex-wrap items-end gap-2">
              <div>
                <label class="mb-1 block text-xs font-bold text-slate-900 dark:text-slate-100">Group</label>
                <select
                  name="group_id"
                  class="h-10 rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-2 text-sm font-medium text-slate-900 dark:text-slate-100"
                >
                  <%= for g <- @all_groups do %>
                    <option value={g.id}>{g.name}</option>
                  <% end %>
                </select>
              </div>
              <div>
                <label class="mb-1 block text-xs font-bold text-slate-900 dark:text-slate-100">Permission</label>
                <select
                  name="permission"
                  class="h-10 rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-2 text-sm font-medium text-slate-900 dark:text-slate-100"
                >
                  <option value="read">read</option><option value="write">write</option><option value="admin">
                    admin
                  </option>
                </select>
              </div>
              <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">Grant</button>
            </form>
          <% else %>
            <p class="text-sm font-medium text-slate-700 dark:text-slate-300">
              Select a bucket on the left to manage grants.
            </p>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
