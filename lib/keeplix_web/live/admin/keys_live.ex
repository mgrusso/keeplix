defmodule KeeplixWeb.Admin.KeysLive do
  use KeeplixWeb, :live_view

  alias Keeplix.Accounts
  alias Keeplix.Audit
  alias KeeplixWeb.LiveParams

  def mount(_params, session, socket) do
    user = get_user(session)

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:all_users, Accounts.list_users())
     |> stream(:keys, Accounts.list_all_keys())}
  end

  defp get_user(%{"user_id" => id}), do: Accounts.get_user(id)
  defp get_user(_), do: nil

  defp format_used(nil), do: "never"

  defp format_used(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp format_used(%NaiveDateTime{} = dt),
    do: dt |> DateTime.from_naive!("Etc/UTC") |> format_used()

  def handle_event("create", %{"user_id" => raw_uid, "description" => desc}, socket) do
    with {:ok, uid} <- LiveParams.id(raw_uid),
         %Accounts.User{} = owner <- Accounts.get_user(uid),
         {:ok, record, %{access_key_id: akid, secret: secret}} <-
           Accounts.create_access_key(owner, desc) do
      Audit.log(socket.assigns.current_user, "key.create", akid, %{owner: owner.username})

      {:noreply,
       socket
       |> stream_insert(:keys, Accounts.get_access_key!(record.id))
       |> assign(:new_secret, %{username: owner.username, access_key_id: akid, secret: secret})
       |> put_flash(:info, "Key created for #{owner.username}. Secret shown only once!")}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Failed to create key.")}
    end
  end

  def handle_event("toggle", %{"id" => raw}, socket) do
    with {:ok, id} <- LiveParams.id(raw),
         %Accounts.AccessKey{} = key <- Accounts.get_access_key(id),
         {:ok, updated} <- Accounts.set_key_active(key, !key.active) do
      Audit.log(socket.assigns.current_user, "key.toggle", key.access_key_id, %{
        active: updated.active
      })

      {:noreply, socket |> stream_insert(:keys, Accounts.get_access_key!(updated.id))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Key not found.")}
    end
  end

  def handle_event("delete", %{"id" => raw}, socket) do
    with {:ok, id} <- LiveParams.id(raw),
         %Accounts.AccessKey{} = key <- Accounts.get_access_key(id),
         {:ok, _} <- Accounts.delete_access_key(key.id) do
      Audit.log(socket.assigns.current_user, "key.delete", key.access_key_id, %{})
      {:noreply, socket |> stream_delete(:keys, key) |> put_flash(:info, "Key deleted.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Key not found.")}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <h1 class="text-3xl font-bold text-slate-900 dark:text-slate-100">Access keys</h1>
      <p class="mt-1 text-sm font-medium text-slate-700 dark:text-slate-300">
        All keys across users. Secrets are shown only once, at creation.
      </p>

      <%= if assigns[:new_secret] do %>
        <div class="mt-4 rounded-xl border-2 border-amber-500 dark:border-amber-800 bg-amber-50 dark:bg-amber-950 p-4 shadow-sm">
          <p class="font-bold text-amber-900 dark:text-amber-200">
            Copy now for {@new_secret.username} – it will not be shown again:
          </p>
          <div class="mt-2 font-mono text-sm font-bold text-slate-900 dark:text-slate-100">
            AccessKey: {@new_secret.access_key_id}
          </div>
          <div class="font-mono text-sm font-bold text-slate-900 dark:text-slate-100">
            Secret: {@new_secret.secret}
          </div>
        </div>
      <% end %>

      <form
        phx-submit="create"
        class="mt-5 flex flex-wrap items-end gap-2 rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 shadow-sm"
      >
        <div>
          <label
            for="keys-user"
            class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
          >User</label>
          <select
            id="keys-user"
            name="user_id"
            class="h-10 rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-2 text-sm font-medium text-slate-900 dark:text-slate-100"
          >
            <%= for u <- @all_users do %>
              <option value={u.id}>{u.username}</option>
            <% end %>
          </select>
        </div>
        <div>
          <label
            for="keys-desc"
            class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
          >Description</label>
          <input
            id="keys-desc"
            name="description"
            placeholder="e.g. backup job"
            class="h-10 w-64 rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-3 text-sm text-slate-900 dark:text-slate-100 placeholder:text-slate-500 dark:placeholder:text-slate-400"
          />
        </div>
        <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">Create key</button>
      </form>

      <div class="mt-4 overflow-x-auto rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 shadow-sm">
        <table class="w-full min-w-[640px] text-left text-sm">
          <thead class="bg-slate-100 dark:bg-slate-800 text-xs font-bold uppercase tracking-wide text-slate-800 dark:text-slate-200">
            <tr>
              <th class="px-4 py-3">Access key</th><th class="px-4 py-3">Owner</th><th class="px-4 py-3">
                Description
              </th><th class="px-4 py-3">Status</th><th class="px-4 py-3">Last used</th><th class="px-4 py-3 text-right">
                Actions
              </th>
            </tr>
          </thead>
          <tbody id="keys" phx-update="stream">
            <tr
              :for={{id, k} <- @streams.keys}
              id={id}
              class="border-t border-slate-200 dark:border-slate-700"
            >
              <td class="px-4 py-3 font-mono font-bold text-slate-900 dark:text-slate-100">
                {k.access_key_id}
              </td>
              <td class="px-4 py-3 font-semibold text-slate-900 dark:text-slate-100">
                {if k.user, do: k.user.username, else: "—"}
              </td>
              <td class="px-4 py-3 text-slate-800 dark:text-slate-200">{k.description}</td>
              <td class="px-4 py-3 font-semibold text-slate-800 dark:text-slate-200">
                {if k.active, do: "active", else: "disabled"}
              </td>
              <td class="px-4 py-3 text-xs font-medium text-slate-600 dark:text-slate-400">
                {format_used(k.last_used_at)}
              </td>
              <td class="px-4 py-3">
                <div class="flex justify-end gap-2">
                  <button
                    phx-click="toggle"
                    phx-value-id={k.id}
                    class="rounded-lg border border-slate-300 dark:border-slate-700 px-3 py-1.5 font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
                  >Enable/Disable</button>
                  <button
                    phx-click="delete"
                    phx-value-id={k.id}
                    data-confirm="Really delete this key?"
                    class="rounded-lg border border-red-300 dark:border-red-800 px-3 py-1.5 font-semibold text-red-700 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950"
                  >Delete</button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
