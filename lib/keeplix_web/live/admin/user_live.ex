defmodule KeeplixWeb.Admin.UserLive do
  use KeeplixWeb, :live_view

  alias Keeplix.{Accounts, Buckets}
  alias Keeplix.Audit
  alias KeeplixWeb.LiveParams

  def mount(_params, session, socket) do
    user = get_user(session)

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:form, to_form(%{"username" => "", "password" => "", "role" => "user"}))
     |> assign(:all_groups, Accounts.list_groups())
     |> assign(:selected_user, nil)
     |> assign(:selected_groups, [])
     |> assign(:selected_buckets, [])
     |> assign(:new_secret, nil)
     |> stream(:users, Accounts.list_users())
     |> stream(:user_keys, [])}
  end

  defp get_user(%{"user_id" => id}), do: Accounts.get_user(id)
  defp get_user(_), do: nil

  # ---------- create / delete / suspend ----------

  def handle_event(
        "create",
        %{"username" => username, "password" => password, "role" => role},
        socket
      ) do
    case Accounts.create_user(%{username: username, password: password, role: role}) do
      {:ok, user} ->
        Audit.log(socket.assigns.current_user, "user.create", username, %{role: role})

        {:noreply,
         socket
         |> stream_insert(:users, user)
         |> assign(:all_groups, Accounts.list_groups())
         |> put_flash(:info, "User created. Select them to manage groups and keys.")}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(cs.errors)}")}
    end
  end

  def handle_event("delete", %{"id" => raw}, socket) do
    with {:ok, id} <- LiveParams.id(raw),
         %Accounts.User{} = user <- Accounts.get_user(id) do
      me = socket.assigns.current_user

      cond do
        user.id == me.id ->
          {:noreply, put_flash(socket, :error, "You cannot delete your own account.")}

        user.role == "admin" and Accounts.count_admins() <= 1 ->
          {:noreply, put_flash(socket, :error, "You cannot delete the last admin.")}

        true ->
          {:ok, _} = Accounts.delete_user(user)
          Audit.log(socket.assigns.current_user, "user.delete", user.username, %{})

          socket =
            socket
            |> stream_delete(:users, user)
            |> put_flash(:info, "User deleted.")

          socket =
            if socket.assigns.selected_user && socket.assigns.selected_user.id == user.id do
              socket
              |> assign(:selected_user, nil)
              |> assign(:new_secret, nil)
              |> stream(:user_keys, [], reset: true)
            else
              socket
            end

          {:noreply, socket}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "User not found.")}
    end
  end

  def handle_event("toggle-active", %{"id" => raw}, socket) do
    with {:ok, id} <- LiveParams.id(raw),
         %Accounts.User{} = user <- Accounts.get_user(id) do
      me = socket.assigns.current_user

      cond do
        user.id == me.id and user.is_active ->
          {:noreply, put_flash(socket, :error, "You cannot suspend your own account.")}

        user.role == "admin" and user.is_active and Accounts.count_admins() <= 1 ->
          {:noreply, put_flash(socket, :error, "You cannot suspend the last admin.")}

        true ->
          {:ok, updated} = Accounts.update_user(user, %{is_active: !user.is_active})

          Audit.log(
            socket.assigns.current_user,
            if(updated.is_active, do: "user.activate", else: "user.suspend"),
            user.username,
            %{}
          )

          socket =
            socket
            |> stream_insert(:users, updated)
            |> refresh_selected(updated)

          {:noreply, socket}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "User not found.")}
    end
  end

  # ---------- select ----------

  def handle_event("select", %{"id" => raw}, socket) do
    with {:ok, id} <- LiveParams.id(raw),
         %Accounts.User{} = user <- Accounts.get_user(id) do
      {:noreply, load_selected(socket, user)}
    else
      _ -> {:noreply, put_flash(socket, :error, "User not found.")}
    end
  end

  # ---------- profile ----------

  def handle_event(
        "save-profile",
        %{"display_name" => display_name, "email" => email, "role" => role},
        socket
      ) do
    user = socket.assigns.selected_user
    me = socket.assigns.current_user

    cond do
      user.id == me.id and user.role == "admin" and role != "admin" ->
        {:noreply, put_flash(socket, :error, "You cannot demote your own account.")}

      user.role == "admin" and role != "admin" and Accounts.count_admins() <= 1 ->
        {:noreply, put_flash(socket, :error, "You cannot demote the last admin.")}

      true ->
        case Accounts.update_user(user, %{display_name: display_name, email: email, role: role}) do
          {:ok, updated} ->
            Audit.log(me, "user.profile", user.username, %{role: role})

            {:noreply,
             socket
             |> stream_insert(:users, updated)
             |> load_selected(updated)
             |> put_flash(:info, "Profile updated.")}

          {:error, cs} ->
            {:noreply, put_flash(socket, :error, "Error: #{inspect(cs.errors)}")}
        end
    end
  end

  def handle_event("reset-password", %{"password" => password}, socket) do
    user = socket.assigns.selected_user

    cond do
      password == nil or String.length(password) < 8 ->
        {:noreply, put_flash(socket, :error, "Password must have at least 8 characters.")}

      true ->
        case Accounts.update_user(user, %{password: password}) do
          {:ok, updated} ->
            Audit.log(socket.assigns.current_user, "user.password_reset", user.username, %{})

            {:noreply,
             socket
             |> stream_insert(:users, updated)
             |> load_selected(updated)
             |> put_flash(:info, "Password reset.")}

          {:error, cs} ->
            {:noreply, put_flash(socket, :error, "Error: #{inspect(cs.errors)}")}
        end
    end
  end

  def handle_event("reset-2fa", _, socket) do
    case socket.assigns.selected_user do
      nil ->
        {:noreply, put_flash(socket, :error, "Select a user first.")}

      user ->
        Keeplix.WebAuthn.reset_2fa(user)
        Audit.log(socket.assigns.current_user, "admin.webauthn_reset", user.username, %{})

        {:noreply,
         socket
         |> load_selected(Accounts.get_user!(user.id))
         |> put_flash(:info, "Two-factor methods removed.")}
    end
  end

  # ---------- groups ----------

  def handle_event("add-group", %{"group_id" => raw}, socket) do
    with %Accounts.User{} = user <- socket.assigns.selected_user,
         {:ok, gid} <- LiveParams.id(raw),
         %Accounts.Group{} = group <- Accounts.get_group(gid) do
      Accounts.add_user_to_group(user, group)
      {:noreply, load_selected(socket, Accounts.get_user!(user.id))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid user or group.")}
    end
  end

  def handle_event("remove-group", %{"group_id" => raw}, socket) do
    with %Accounts.User{} = user <- socket.assigns.selected_user,
         {:ok, gid} <- LiveParams.id(raw),
         %Accounts.Group{} = group <- Accounts.get_group(gid) do
      Accounts.remove_user_from_group(user, group)
      {:noreply, load_selected(socket, Accounts.get_user!(user.id))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid user or group.")}
    end
  end

  # ---------- keys ----------

  def handle_event("create-key", %{"description" => desc}, socket) do
    user = socket.assigns.selected_user

    case Accounts.create_access_key(user, desc) do
      {:ok, record, %{access_key_id: akid, secret: secret}} ->
        {:noreply,
         socket
         |> stream_insert(:user_keys, record)
         |> assign(:new_secret, %{access_key_id: akid, secret: secret})
         |> put_flash(:info, "Key created. Secret shown only once!")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create key.")}
    end
  end

  def handle_event("toggle-key", %{"id" => raw}, socket) do
    with {:ok, id} <- LiveParams.id(raw),
         %Accounts.AccessKey{} = key <- Accounts.get_access_key(id),
         {:ok, updated} <- Accounts.set_key_active(key, !key.active) do
      {:noreply, socket |> stream_insert(:user_keys, Accounts.get_access_key!(updated.id))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Key not found.")}
    end
  end

  def handle_event("delete-key", %{"id" => raw}, socket) do
    with {:ok, id} <- LiveParams.id(raw),
         %Accounts.AccessKey{} = key <- Accounts.get_access_key(id),
         {:ok, _} <- Accounts.delete_access_key(key.id) do
      {:noreply, socket |> stream_delete(:user_keys, key) |> put_flash(:info, "Key deleted.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Key not found.")}
    end
  end

  defp load_selected(socket, user) do
    socket
    |> assign(:selected_user, user)
    |> assign(:selected_groups, Accounts.user_groups(user))
    |> assign(:selected_buckets, Buckets.visible_buckets(user))
    |> assign(:new_secret, nil)
    |> assign(:webauthn_count, length(Keeplix.WebAuthn.list_credentials(user)))
    |> assign(:backup_count, Keeplix.WebAuthn.remaining_backup_codes(user))
    |> stream(:user_keys, Accounts.list_keys_for_user(user.id), reset: true)
  end

  defp refresh_selected(socket, updated) do
    if socket.assigns.selected_user && socket.assigns.selected_user.id == updated.id do
      load_selected(socket, updated)
    else
      socket
    end
  end

  # ---------- render ----------

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <h1 class="text-3xl font-bold text-slate-900 dark:text-slate-100">Users</h1>
      <p class="mt-1 text-sm font-medium text-slate-700 dark:text-slate-300">
        Create users, then select one to manage profile, groups, access keys, and buckets.
      </p>

      <div class="mt-5 rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 shadow-sm">
        <.form for={@form} phx-submit="create" id="user-form" class="flex flex-wrap items-end gap-3">
          <.input
            field={@form[:username]}
            label="Name"
            class="h-10 rounded-lg border-slate-300 dark:border-slate-700 text-slate-900 dark:text-slate-100"
          />
          <.input
            field={@form[:password]}
            label="Password"
            type="password"
            class="h-10 rounded-lg border-slate-300 dark:border-slate-700 text-slate-900 dark:text-slate-100"
          />
          <.input
            field={@form[:role]}
            label="Role"
            type="select"
            options={["user", "admin"]}
            class="h-10 rounded-lg border-slate-300 dark:border-slate-700 text-slate-900 dark:text-slate-100"
          />
          <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">Create</button>
        </.form>
      </div>

      <div class="mt-4 grid gap-5 lg:grid-cols-2">
        <div class="overflow-x-auto rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 shadow-sm">
          <table class="w-full min-w-[640px] text-left text-sm">
            <thead class="bg-slate-100 dark:bg-slate-800 text-xs font-bold uppercase tracking-wide text-slate-800 dark:text-slate-200">
              <tr>
                <th class="px-4 py-3">Name</th><th class="px-4 py-3">Role</th><th class="px-4 py-3">
                  Status
                </th><th class="px-4 py-3 text-right">Actions</th>
              </tr>
            </thead>
            <tbody id="users" phx-update="stream">
              <tr
                :for={{id, u} <- @streams.users}
                id={id}
                class="border-t border-slate-200 dark:border-slate-700"
              >
                <td class="px-4 py-3 font-mono font-bold text-slate-900 dark:text-slate-100">
                  {u.username}
                </td>
                <td class="px-4 py-3">
                  <span class="rounded-full bg-slate-100 dark:bg-slate-800 px-2.5 py-1 text-xs font-bold text-slate-900 dark:text-slate-100">{u.role}</span>
                </td>
                <td class="px-4 py-3 font-semibold text-slate-800 dark:text-slate-200">
                  {if u.is_active, do: "active", else: "suspended"}
                </td>
                <td class="px-4 py-3">
                  <div class="flex justify-end gap-2">
                    <button
                      phx-click="select"
                      phx-value-id={u.id}
                      class="rounded-lg border border-slate-300 dark:border-slate-700 px-3 py-1.5 font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
                    >Manage</button>
                    <button
                      phx-click="toggle-active"
                      phx-value-id={u.id}
                      class="rounded-lg border border-slate-300 dark:border-slate-700 px-3 py-1.5 font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
                    >Suspend/Activate</button>
                    <button
                      phx-click="delete"
                      phx-value-id={u.id}
                      data-confirm="Really delete this user with all their keys?"
                      class="rounded-lg border border-red-300 dark:border-red-800 px-3 py-1.5 font-semibold text-red-700 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950"
                    >Delete</button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-5 shadow-sm">
          <%= if @selected_user do %>
            <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">
              Manage: <span class="font-mono">{@selected_user.username}</span>
            </h2>

            <form
              phx-submit="save-profile"
              class="mt-4 space-y-3 border-t border-slate-200 dark:border-slate-700 pt-4"
            >
              <h3 class="text-sm font-bold text-slate-900 dark:text-slate-100">Profile</h3>
              <div class="grid gap-3 sm:grid-cols-2">
                <div>
                  <label
                    for="profile-display"
                    class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
                  >Display name</label>
                  <input
                    id="profile-display"
                    name="display_name"
                    value={@selected_user.display_name}
                    class="h-10 w-full rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm text-slate-900 dark:text-slate-100"
                  />
                </div>
                <div>
                  <label
                    for="profile-email"
                    class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
                  >Email</label>
                  <input
                    id="profile-email"
                    name="email"
                    value={@selected_user.email}
                    class="h-10 w-full rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm text-slate-900 dark:text-slate-100"
                  />
                </div>
                <div>
                  <label
                    for="profile-role"
                    class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
                  >Role</label>
                  <select
                    id="profile-role"
                    name="role"
                    class="h-10 w-full rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-2 text-sm font-medium text-slate-900 dark:text-slate-100"
                  >
                    <option value="user" selected={@selected_user.role == "user"}>user</option>
                    <option value="admin" selected={@selected_user.role == "admin"}>admin</option>
                  </select>
                </div>
              </div>
              <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">Save profile</button>
            </form>

            <form
              phx-submit="reset-password"
              class="mt-4 space-y-3 border-t border-slate-200 dark:border-slate-700 pt-4"
            >
              <h3 class="text-sm font-bold text-slate-900 dark:text-slate-100">Reset password</h3>
              <div class="flex flex-wrap items-end gap-2">
                <div>
                  <label
                    for="new-password"
                    class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
                  >New password (min. 8 chars)</label>
                  <input
                    id="new-password"
                    name="password"
                    type="password"
                    class="h-10 w-64 rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm text-slate-900 dark:text-slate-100"
                  />
                </div>
                <button class="h-10 rounded-lg border border-slate-300 dark:border-slate-700 px-4 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800">Set password</button>
              </div>
            </form>

            <div class="mt-4 border-t border-slate-200 dark:border-slate-700 pt-4">
              <h3 class="text-sm font-bold text-slate-900 dark:text-slate-100">
                Two-factor authentication
              </h3>
              <p class="mt-1 text-sm font-medium text-slate-700 dark:text-slate-300">
                {@webauthn_count} passkey(s), {@backup_count} backup code(s) remaining.
              </p>
              <button
                phx-click="reset-2fa"
                data-confirm="Remove all passkeys and backup codes of this user? They can sign in with password/OIDC again."
                class="mt-2 h-10 rounded-lg border border-red-300 px-4 text-sm font-semibold text-red-700 hover:bg-red-50 dark:hover:bg-red-950"
              >Remove two-factor methods</button>
            </div>

            <div class="mt-4 border-t border-slate-200 dark:border-slate-700 pt-4">
              <h3 class="text-sm font-bold text-slate-900 dark:text-slate-100">Groups</h3>
              <ul class="mt-2 space-y-2 text-sm">
                <%= for g <- @selected_groups do %>
                  <li class="flex items-center gap-2 rounded-lg border border-slate-200 dark:border-slate-700 px-3 py-2">
                    <span class="font-mono font-bold text-slate-900 dark:text-slate-100">{g.name}</span>
                    <button
                      phx-click="remove-group"
                      phx-value-group_id={g.id}
                      class="ml-auto font-semibold text-red-700 dark:text-red-400 hover:underline"
                    >Remove</button>
                  </li>
                <% end %>
              </ul>
              <%= if @selected_groups == [] do %>
                <p class="mt-2 text-sm font-medium text-slate-700 dark:text-slate-300">
                  No group memberships.
                </p>
              <% end %>
              <form phx-submit="add-group" class="mt-3 flex flex-wrap items-center gap-2">
                <select
                  name="group_id"
                  class="h-10 rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-2 text-sm font-medium text-slate-900 dark:text-slate-100"
                >
                  <%= for g <- @all_groups do %>
                    <option value={g.id}>{g.name}</option>
                  <% end %>
                </select>
                <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">Add to group</button>
              </form>
            </div>

            <div class="mt-4 border-t border-slate-200 dark:border-slate-700 pt-4">
              <h3 class="text-sm font-bold text-slate-900 dark:text-slate-100">Access keys</h3>
              <%= if @new_secret do %>
                <div class="mt-2 rounded-xl border-2 border-amber-500 dark:border-amber-800 bg-amber-50 dark:bg-amber-950 p-3">
                  <p class="text-sm font-bold text-amber-900 dark:text-amber-200">
                    Copy now – it will not be shown again:
                  </p>
                  <div class="mt-1 font-mono text-sm font-bold text-slate-900 dark:text-slate-100">
                    AccessKey: {@new_secret.access_key_id}
                  </div>
                  <div class="font-mono text-sm font-bold text-slate-900 dark:text-slate-100">
                    Secret: {@new_secret.secret}
                  </div>
                </div>
              <% end %>
              <form phx-submit="create-key" class="mt-3 flex flex-wrap items-end gap-2">
                <div>
                  <label
                    for="key-desc"
                    class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
                  >Description</label>
                  <input
                    id="key-desc"
                    name="description"
                    placeholder="e.g. backup job"
                    class="h-10 w-56 rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm text-slate-900 dark:text-slate-100 placeholder:text-slate-500 dark:placeholder:text-slate-400"
                  />
                </div>
                <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">Create key</button>
              </form>
              <div id="user-keys" phx-update="stream" class="mt-3 space-y-2">
                <div
                  id="no-user-keys"
                  class="hidden only:block rounded-lg bg-slate-50 dark:bg-slate-800 p-3 text-sm font-medium text-slate-700 dark:text-slate-300"
                >
                  No keys for this user.
                </div>
                <div
                  :for={{dom_id, k} <- @streams.user_keys}
                  id={dom_id}
                  class="flex flex-wrap items-center gap-2 rounded-lg border border-slate-200 dark:border-slate-700 px-3 py-2 text-sm"
                >
                  <code class="rounded bg-slate-100 dark:bg-slate-800 px-2 py-0.5 font-mono font-bold text-slate-900 dark:text-slate-100">{k.access_key_id}</code>
                  <span class="font-semibold text-slate-800 dark:text-slate-200">{if k.active,
                    do: "active",
                    else: "disabled"}</span>
                  <div class="ml-auto flex gap-2">
                    <button
                      phx-click="toggle-key"
                      phx-value-id={k.id}
                      class="rounded-lg border border-slate-300 dark:border-slate-700 px-2.5 py-1 font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
                    >Enable/Disable</button>
                    <button
                      phx-click="delete-key"
                      phx-value-id={k.id}
                      data-confirm="Really delete this key?"
                      class="rounded-lg border border-red-300 dark:border-red-800 px-2.5 py-1 font-semibold text-red-700 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950"
                    >Delete</button>
                  </div>
                </div>
              </div>
            </div>

            <div class="mt-4 border-t border-slate-200 dark:border-slate-700 pt-4">
              <h3 class="text-sm font-bold text-slate-900 dark:text-slate-100">
                Visible buckets ({length(@selected_buckets)})
              </h3>
              <ul class="mt-2 space-y-1 text-sm">
                <%= for b <- @selected_buckets do %>
                  <li class="font-mono font-semibold text-slate-900 dark:text-slate-100">{b.name}</li>
                <% end %>
              </ul>
              <%= if @selected_buckets == [] do %>
                <p class="mt-1 text-sm font-medium text-slate-700 dark:text-slate-300">
                  No bucket access. Grant access under “All buckets”.
                </p>
              <% end %>
            </div>
          <% else %>
            <p class="text-sm font-medium text-slate-700 dark:text-slate-300">
              Select a user on the left to manage profile, groups, access keys, and see their buckets.
            </p>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
