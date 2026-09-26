defmodule KeeplixWeb.Admin.DashboardLive do
  use KeeplixWeb, :live_view

  import Ecto.Query

  alias Keeplix.Repo

  def mount(_params, session, socket) do
    user = get_user(session)

    stats = %{
      users: Repo.aggregate(Keeplix.Accounts.User, :count),
      groups: Repo.aggregate(Keeplix.Accounts.Group, :count),
      buckets: Repo.aggregate(Keeplix.Buckets.Bucket, :count),
      keys: Repo.aggregate(Keeplix.Accounts.AccessKey, :count),
      objects: count_objects()
    }

    recent_buckets =
      Repo.all(from b in Keeplix.Buckets.Bucket, order_by: [desc: b.inserted_at], limit: 5)
      |> Repo.preload(:owner)

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:stats, stats)
     |> assign(:recent_buckets, recent_buckets)
     |> assign(:oidc_enabled, Keeplix.Oidc.enabled?())
     |> assign(:replication, Keeplix.Replication.status())}
  end

  defp get_user(%{"user_id" => id}), do: Keeplix.Accounts.get_user(id)
  defp get_user(_), do: nil

  defp count_objects do
    import Ecto.Query

    Repo.aggregate(
      from(o in Keeplix.Storage.Object, where: o.is_latest == true and o.deleted == false),
      :count
    )
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <h1 class="text-3xl font-bold text-slate-900 dark:text-slate-100">Admin dashboard</h1>
      <p class="mt-1 text-sm font-medium text-slate-700 dark:text-slate-300">
        System overview and shortcuts to admin tasks.
      </p>

      <div class="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
        <div class="rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 shadow-sm">
          <p class="text-xs font-bold uppercase tracking-wide text-slate-700 dark:text-slate-300">
            Users
          </p>
          <p class="mt-1 text-3xl font-bold text-slate-900 dark:text-slate-100">{@stats.users}</p>
          <.link
            navigate="/admin/users"
            class="mt-2 inline-block text-sm font-semibold text-slate-900 dark:text-slate-100 underline"
          >Manage</.link>
        </div>
        <div class="rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 shadow-sm">
          <p class="text-xs font-bold uppercase tracking-wide text-slate-700 dark:text-slate-300">
            Groups
          </p>
          <p class="mt-1 text-3xl font-bold text-slate-900 dark:text-slate-100">{@stats.groups}</p>
          <.link
            navigate="/admin/groups"
            class="mt-2 inline-block text-sm font-semibold text-slate-900 dark:text-slate-100 underline"
          >Manage</.link>
        </div>
        <div class="rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 shadow-sm">
          <p class="text-xs font-bold uppercase tracking-wide text-slate-700 dark:text-slate-300">
            Buckets
          </p>
          <p class="mt-1 text-3xl font-bold text-slate-900 dark:text-slate-100">{@stats.buckets}</p>
          <.link
            navigate="/admin/buckets"
            class="mt-2 inline-block text-sm font-semibold text-slate-900 dark:text-slate-100 underline"
          >Manage</.link>
        </div>
        <div class="rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 shadow-sm">
          <p class="text-xs font-bold uppercase tracking-wide text-slate-700 dark:text-slate-300">
            Access keys
          </p>
          <p class="mt-1 text-3xl font-bold text-slate-900 dark:text-slate-100">{@stats.keys}</p>
          <.link
            navigate="/admin/keys"
            class="mt-2 inline-block text-sm font-semibold text-slate-900 dark:text-slate-100 underline"
          >Manage</.link>
        </div>
        <div class="rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 shadow-sm">
          <p class="text-xs font-bold uppercase tracking-wide text-slate-700 dark:text-slate-300">
            Objects
          </p>
          <p class="mt-1 text-3xl font-bold text-slate-900 dark:text-slate-100">{@stats.objects}</p>
          <p class="mt-2 text-xs font-medium text-slate-600 dark:text-slate-400">
            current versions
          </p>
        </div>
      </div>

      <div class="mt-5 grid gap-5 md:grid-cols-2">
        <section class="rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-5 shadow-sm">
          <h2 class="font-bold text-slate-900 dark:text-slate-100">Recent buckets</h2>
          <%= if @recent_buckets == [] do %>
            <p class="mt-2 text-sm font-medium text-slate-700 dark:text-slate-300">No buckets yet.</p>
          <% else %>
            <ul class="mt-3 space-y-2 text-sm">
              <%= for b <- @recent_buckets do %>
                <li class="flex items-center gap-2 rounded-lg border border-slate-200 dark:border-slate-700 px-3 py-2">
                  <span class="font-mono font-bold text-slate-900 dark:text-slate-100">{b.name}</span>
                  <span class="text-slate-700 dark:text-slate-300">{if b.owner,
                    do: "owner: " <> b.owner.username,
                    else: "no owner"}</span>
                </li>
              <% end %>
            </ul>
          <% end %>
        </section>
        <section class="rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-5 shadow-sm">
          <h2 class="font-bold text-slate-900 dark:text-slate-100">Integrations</h2>
          <dl class="mt-3 space-y-2 text-sm">
            <div class="flex items-center gap-2">
              <dt class="font-semibold text-slate-900 dark:text-slate-100">Single sign-on:</dt>
              <dd class="font-medium text-slate-700 dark:text-slate-300">
                {if @oidc_enabled, do: "enabled", else: "disabled"} — set OIDC_* env vars to configure
              </dd>
            </div>
            <div class="flex items-center gap-2">
              <dt class="font-semibold text-slate-900 dark:text-slate-100">Replication:</dt>
              <dd class="font-medium text-slate-700 dark:text-slate-300">
                {@replication.mode} ({@replication.note})
              </dd>
            </div>
          </dl>
          <h2 class="mt-5 font-bold text-slate-900 dark:text-slate-100">Common tasks</h2>
          <ul class="mt-2 list-disc pl-5 text-sm font-medium text-slate-800 dark:text-slate-200">
            <li>Create a user, then select them to set groups and access keys.</li>
            <li>Grant a user or group read / write / admin on a bucket.</li>
            <li>Revoke or delete keys of users who left.</li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
