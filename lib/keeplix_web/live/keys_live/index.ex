defmodule KeeplixWeb.KeysLive.Index do
  use KeeplixWeb, :live_view

  alias Keeplix.Accounts
  alias Keeplix.Audit
  alias KeeplixWeb.LiveParams

  def mount(_params, session, socket) do
    user = get_user(session)
    keys = if user, do: Accounts.list_keys_for_user(user.id), else: []

    {:ok,
     socket |> assign(:current_user, user) |> assign(:description, "") |> stream(:keys, keys)}
  end

  defp get_user(%{"user_id" => id}), do: Accounts.get_user(id)
  defp get_user(_), do: nil

  def handle_event("create", %{"description" => desc}, socket) do
    with %{id: uid} <- socket.assigns.current_user,
         %Accounts.User{is_active: true} = user <- Accounts.get_user(uid),
         {:ok, record, %{access_key_id: akid, secret: secret}} <-
           Accounts.create_access_key(user, desc) do
      Audit.log(user, "key.create", akid, %{})

      {:noreply,
       socket
       |> stream_insert(:keys, record)
       |> assign(:new_secret, %{access_key_id: akid, secret: secret})
       |> put_flash(:info, gettext("Key created. The secret is shown only once!"))}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Failed to create key."))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %{id: uid} <- socket.assigns.current_user,
         {:ok, key_id} <- LiveParams.id(id),
         %Accounts.AccessKey{user_id: key_uid} = key <- Accounts.get_access_key(key_id),
         true <- key_uid == uid,
         {:ok, _} <- Accounts.delete_access_key(key.id) do
      Audit.log(socket.assigns.current_user, "key.delete", key.access_key_id, %{})

      {:noreply,
       socket
       |> stream_delete(:keys, key)
       |> put_flash(:info, gettext("Key deleted."))}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  def handle_event("rotate", %{"id" => id}, socket) do
    with %{id: uid} <- socket.assigns.current_user,
         %Accounts.User{is_active: true} = user <- Accounts.get_user(uid),
         {:ok, key_id} <- LiveParams.id(id),
         %Accounts.AccessKey{user_id: key_uid} = old <- Accounts.get_access_key(key_id),
         true <- key_uid == uid,
         desc = (old.description || "key") <> " (rotated)",
         {:ok, record, %{access_key_id: akid, secret: secret}} <-
           Accounts.create_access_key(user, desc),
         {:ok, _} <- Accounts.delete_access_key(old.id) do
      Audit.log(user, "key.rotate", akid, %{replaces: old.access_key_id})

      {:noreply,
       socket
       |> stream_delete(:keys, old)
       |> stream_insert(:keys, record)
       |> assign(:new_secret, %{access_key_id: akid, secret: secret})
       |> put_flash(:info, gettext("Key rotated. The new secret is shown only once!"))}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  defp format_used(nil), do: "never"

  defp format_used(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp format_used(%NaiveDateTime{} = dt),
    do: dt |> DateTime.from_naive!("Etc/UTC") |> format_used()

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <h1 class="text-3xl font-bold text-slate-900 dark:text-slate-100">{gettext("Access keys")}</h1>
      <p class="mt-1 text-sm font-medium text-slate-700 dark:text-slate-300">
        {gettext("For S3 clients (AWS CLI, SDKs). The secret is shown only once.")}
      </p>

      <%= if assigns[:new_secret] do %>
        <div class="mt-4 rounded-xl border-2 border-amber-500 dark:border-amber-800 bg-amber-50 dark:bg-amber-950 p-4 shadow-sm">
          <p class="font-bold text-amber-900 dark:text-amber-200">
            {gettext("Copy now – it will not be shown again:")}
          </p>
          <div class="mt-2 font-mono text-sm font-bold text-slate-900 dark:text-slate-100">
            AccessKey: {@new_secret.access_key_id}
            <button
              type="button"
              id="copy-access-key"
              phx-hook=".CopyKeyButton"
              data-copy={@new_secret.access_key_id}
              class="ml-2 rounded-lg border border-amber-600 dark:border-amber-700 px-2 py-0.5 font-sans text-xs font-semibold text-amber-900 dark:text-amber-200 hover:bg-amber-100 dark:hover:bg-amber-900"
            >{gettext("Copy")}</button>
          </div>
          <div class="font-mono text-sm font-bold text-slate-900 dark:text-slate-100">
            Secret: {@new_secret.secret}
            <button
              type="button"
              id="copy-secret"
              phx-hook=".CopyKeyButton"
              data-copy={@new_secret.secret}
              class="ml-2 rounded-lg border border-amber-600 dark:border-amber-700 px-2 py-0.5 font-sans text-xs font-semibold text-amber-900 dark:text-amber-200 hover:bg-amber-100 dark:hover:bg-amber-900"
            >{gettext("Copy")}</button>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyKeyButton">
              export default {
                mounted() {
                  const fallback = () => {
                    const ta = document.createElement("textarea");
                    ta.value = this.el.dataset.copy || "";
                    document.body.appendChild(ta);
                    ta.select();
                    try { document.execCommand("copy"); done(); } catch (_e) { /* ignore */ }
                    document.body.removeChild(ta);
                  };
                  const done = () => {
                    const orig = this.el.textContent;
                    this.el.textContent = "Copied!";
                    setTimeout(() => { this.el.textContent = orig; }, 1200);
                  };
                  this.el.addEventListener("click", () => {
                    if (navigator.clipboard && window.isSecureContext) {
                      navigator.clipboard.writeText(this.el.dataset.copy || "").then(done, fallback);
                    } else {
                      fallback();
                    }
                  });
                }
              }
            </script>
          </div>
        </div>
      <% end %>

      <form
        phx-submit="create"
        class="mt-5 flex flex-wrap items-end gap-2 rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 shadow-sm"
      >
        <div>
          <label
            for="key-desc"
            class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
          >{gettext("Description")}</label>
          <input
            id="key-desc"
            name="description"
            placeholder={gettext("e.g. laptop")}
            class="h-10 w-64 rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-3 text-sm text-slate-900 dark:text-slate-100 placeholder:text-slate-500 dark:placeholder:text-slate-400"
          />
        </div>
        <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">{gettext(
          "Create"
        )}</button>
      </form>

      <div id="keys" phx-update="stream" class="mt-4 space-y-2">
        <div
          id="no-keys"
          class="hidden only:block rounded-xl border border-dashed border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-6 text-center text-sm font-medium text-slate-700 dark:text-slate-300"
        >
          {gettext("No keys yet.")}
        </div>
        <div
          :for={{id, k} <- @streams.keys}
          id={id}
          class="flex flex-wrap items-center gap-3 rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 shadow-sm"
        >
          <code class="rounded bg-slate-100 dark:bg-slate-800 px-2 py-1 font-mono text-sm font-bold text-slate-900 dark:text-slate-100">{k.access_key_id}</code>
          <span class="text-sm font-medium text-slate-800 dark:text-slate-200">{k.description}</span>
          <span class="text-xs font-medium text-slate-600 dark:text-slate-400">{gettext(
            "Last used: %{time}",
            time: format_used(k.last_used_at)
          )}</span>
          <button
            phx-click="rotate"
            phx-value-id={k.id}
            data-confirm={gettext("Rotate this key? The old key stops working immediately.")}
            class="ml-auto inline-flex h-9 items-center rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800"
          >{gettext("Rotate")}</button>
          <button
            phx-click="delete"
            phx-value-id={k.id}
            data-confirm={gettext("Really delete this key?")}
            class="inline-flex h-9 items-center rounded-lg border border-red-300 dark:border-red-800 px-3 text-sm font-semibold text-red-700 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950"
          >{gettext("Delete")}</button>
        </div>
      </div>

      <div class="mt-6 rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-4 text-sm text-slate-800 dark:text-slate-200 shadow-sm">
        <span class="font-semibold text-slate-900 dark:text-slate-100">{gettext("Example:")}</span>
        <code class="font-mono text-slate-900 dark:text-slate-100" phx-no-curly-interpolation>aws --endpoint-url http://localhost:4000 s3 ls --region us-east-1</code>
      </div>
    </Layouts.app>
    """
  end
end
