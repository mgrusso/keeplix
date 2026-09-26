defmodule KeeplixWeb.BucketLive.Index do
  use KeeplixWeb, :live_view

  alias Keeplix.Buckets

  def mount(_params, session, socket) do
    user = get_user(session)
    buckets = if user, do: Buckets.visible_buckets(user), else: []

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:bucket_name, "")
     |> stream(:buckets, buckets)}
  end

  defp get_user(%{"user_id" => id}), do: Keeplix.Accounts.get_user(id)
  defp get_user(_), do: nil

  def handle_event("create", %{"name" => name}, socket) do
    user = socket.assigns.current_user
    name = String.trim(name)

    case Buckets.create_bucket(name, user) do
      {:ok, bucket} ->
        {:noreply,
         socket
         |> stream_insert(:buckets, bucket)
         |> put_flash(:info, gettext("Bucket %{name} created.", name: name))
         |> assign(:bucket_name, "")}

      {:error, cs} ->
        msg =
          cs
          |> Ecto.Changeset.traverse_errors(fn {m, _} -> m end)
          |> inspect()

        {:noreply,
         put_flash(socket, :error, gettext("Failed to create bucket: %{msg}", msg: msg))}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mb-6 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-3xl font-bold text-slate-900 dark:text-slate-100">{gettext("Buckets")}</h1>
          <p class="mt-1 text-sm font-medium text-slate-700 dark:text-slate-300">
            {gettext("All shared storage in one place.")}
          </p>
        </div>
        <form
          phx-submit="create"
          class="flex flex-wrap items-end gap-2 rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-3 shadow-sm"
        >
          <div>
            <label
              for="new-bucket"
              class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
            >{gettext("New bucket")}</label>
            <input
              id="new-bucket"
              name="name"
              value={@bucket_name}
              placeholder={gettext("e.g. photos-2026")}
              class="h-10 w-64 rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-3 text-sm text-slate-900 dark:text-slate-100 placeholder:text-slate-500 dark:placeholder:text-slate-400"
            />
          </div>
          <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">{gettext(
            "Create"
          )}</button>
        </form>
      </div>
      <div id="buckets" phx-update="stream" class="grid gap-3">
        <div
          id="no-buckets"
          class="hidden only:block rounded-xl border border-dashed border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-8 text-center"
        >
          <p class="font-semibold text-slate-900 dark:text-slate-100">
            {gettext("No visible buckets.")}
          </p>
          <p class="mt-1 text-sm text-slate-700 dark:text-slate-300">
            {gettext("Create one above or ask an admin for access.")}
          </p>
        </div>
        <div
          :for={{id, b} <- @streams.buckets}
          id={id}
          class="flex flex-wrap items-center gap-3 rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 shadow-sm"
        >
          <span class="inline-flex h-10 w-10 items-center justify-center rounded-lg bg-slate-100 dark:bg-slate-800">
            <.icon name="hero-archive-box" class="size-5 text-slate-800 dark:text-slate-200" />
          </span>
          <div class="min-w-0">
            <div class="truncate font-mono text-base font-bold text-slate-900 dark:text-slate-100">
              {b.name}
            </div>
          </div>
          <.link
            navigate={"/app/b/#{b.name}"}
            class="ml-auto inline-flex h-10 items-center rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300"
          >{gettext("Open")}</.link>
        </div>
      </div>
      <div class="mt-6 rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 text-sm text-slate-800 dark:text-slate-200 shadow-sm">
        <span class="font-semibold text-slate-900 dark:text-slate-100">{gettext("S3 endpoint:")}</span>
        <code class="rounded bg-slate-100 dark:bg-slate-800 px-1.5 py-0.5 font-mono text-slate-900 dark:text-slate-100">http(s)://host:port/</code>
        <span>{gettext(" · path style · SigV4. Create access keys under “Access keys”.")}</span>
      </div>
    </Layouts.app>
    """
  end
end
