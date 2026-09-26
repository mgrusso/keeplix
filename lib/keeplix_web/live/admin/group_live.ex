defmodule KeeplixWeb.Admin.GroupLive do
  use KeeplixWeb, :live_view

  alias Keeplix.Accounts
  alias Keeplix.Audit
  alias KeeplixWeb.LiveParams

  def mount(_params, session, socket) do
    user = get_user(session)

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:selected_group, nil)
     |> assign(:members, [])
     |> assign(:all_users, Accounts.list_users())
     |> stream(:groups, Accounts.list_groups())}
  end

  defp get_user(%{"user_id" => id}), do: Accounts.get_user(id)
  defp get_user(_), do: nil

  def handle_event("create", %{"name" => name}, socket) do
    case Accounts.create_group(%{name: String.trim(name)}) do
      {:ok, g} ->
        Audit.log(socket.assigns.current_user, "group.create", g.name, %{})
        {:noreply, socket |> stream_insert(:groups, g) |> put_flash(:info, "Group created.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create group.")}
    end
  end

  def handle_event("delete", %{"id" => raw}, socket) do
    with {:ok, id} <- LiveParams.id(raw),
         %Accounts.Group{} = g <- Accounts.get_group(id),
         {:ok, _} <- Accounts.delete_group(g) do
      Audit.log(socket.assigns.current_user, "group.delete", g.name, %{})
      {:noreply, socket |> stream_delete(:groups, g) |> assign(:selected_group, nil)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Group not found.")}
    end
  end

  def handle_event("select", %{"id" => raw}, socket) do
    with {:ok, id} <- LiveParams.id(raw),
         %Accounts.Group{} = g <- Accounts.get_group(id) do
      members = Accounts.group_members(g)
      {:noreply, socket |> assign(:selected_group, g) |> assign(:members, members)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Group not found.")}
    end
  end

  def handle_event("add-member", %{"user_id" => raw}, socket) do
    with %Accounts.Group{} = group <- socket.assigns.selected_group,
         {:ok, uid} <- LiveParams.id(raw),
         %Accounts.User{} = user <- Accounts.get_user(uid) do
      Accounts.add_user_to_group(user, group)

      Audit.log(socket.assigns.current_user, "group.member_add", group.name, %{
        username: user.username
      })

      {:noreply, assign(socket, :members, Accounts.group_members(group))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid user or group.")}
    end
  end

  def handle_event("remove-member", %{"user_id" => raw}, socket) do
    with %Accounts.Group{} = group <- socket.assigns.selected_group,
         {:ok, uid} <- LiveParams.id(raw),
         %Accounts.User{} = user <- Accounts.get_user(uid) do
      Accounts.remove_user_from_group(user, group)

      Audit.log(socket.assigns.current_user, "group.member_remove", group.name, %{
        username: user.username
      })

      {:noreply, assign(socket, :members, Accounts.group_members(group))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid user or group.")}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <h1 class="text-3xl font-bold text-slate-900 dark:text-slate-100">Groups</h1>
      <p class="mt-1 text-sm font-medium text-slate-700 dark:text-slate-300">
        Groups bundle users for bucket grants.
      </p>

      <form
        phx-submit="create"
        class="mt-5 flex flex-wrap items-end gap-2 rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 shadow-sm"
      >
        <div>
          <label
            for="group-name"
            class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
          >New group</label>
          <input
            id="group-name"
            name="name"
            placeholder="e.g. team-photos"
            class="h-10 w-64 rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-3 text-sm text-slate-900 dark:text-slate-100 placeholder:text-slate-500 dark:placeholder:text-slate-400"
          />
        </div>
        <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">Create</button>
      </form>

      <div class="mt-4 grid gap-5 md:grid-cols-2">
        <div class="rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 shadow-sm">
          <h2 class="font-bold text-slate-900 dark:text-slate-100">All groups</h2>
          <div id="groups" phx-update="stream" class="mt-3 space-y-2">
            <div class="hidden only:block rounded-lg bg-slate-50 dark:bg-slate-800 p-4 text-sm font-medium text-slate-700 dark:text-slate-300">
              No groups yet.
            </div>
            <div
              :for={{id, g} <- @streams.groups}
              id={id}
              class="flex items-center gap-2 rounded-lg border border-slate-200 dark:border-slate-700 px-3 py-2.5"
            >
              <span class="font-mono text-sm font-bold text-slate-900 dark:text-slate-100">{g.name}</span>
              <button
                phx-click="select"
                phx-value-id={g.id}
                class="ml-auto rounded-lg border border-slate-300 dark:border-slate-700 px-3 py-1.5 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
              >Members</button>
              <button
                phx-click="delete"
                phx-value-id={g.id}
                data-confirm="Really delete this group?"
                class="rounded-lg border border-red-300 dark:border-red-800 px-3 py-1.5 text-sm font-semibold text-red-700 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950"
              >Delete</button>
            </div>
          </div>
        </div>
        <div class="rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 shadow-sm">
          <%= if @selected_group do %>
            <h2 class="font-bold text-slate-900 dark:text-slate-100">
              Members: <span class="font-mono">{@selected_group.name}</span>
            </h2>
            <ul class="mt-3 space-y-2 text-sm">
              <%= for m <- @members do %>
                <li class="flex items-center gap-2 rounded-lg border border-slate-200 dark:border-slate-700 px-3 py-2">
                  <span class="font-semibold text-slate-900 dark:text-slate-100">{m.username}</span>
                  <button
                    phx-click="remove-member"
                    phx-value-user_id={m.id}
                    class="ml-auto font-semibold text-red-700 dark:text-red-400 hover:underline"
                  >Remove</button>
                </li>
              <% end %>
            </ul>
            <form phx-submit="add-member" class="mt-4 flex flex-wrap items-center gap-2">
              <select
                name="user_id"
                class="h-10 rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-2 text-sm font-medium text-slate-900 dark:text-slate-100"
              >
                <%= for u <- @all_users do %>
                  <option value={u.id}>{u.username}</option>
                <% end %>
              </select>
              <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">Add</button>
            </form>
          <% else %>
            <p class="text-sm font-medium text-slate-700 dark:text-slate-300">
              Select a group on the left to manage members.
            </p>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
