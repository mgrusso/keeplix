defmodule KeeplixWeb.HelpLive do
  @moduledoc """
  Static help page: S3 access, share links, versioning, shortcuts (B6).
  """
  use KeeplixWeb, :live_view

  @aws_example "aws --endpoint-url https://keeplix.example.com s3 ls s3://my-bucket/\n" <>
                 "aws --endpoint-url https://keeplix.example.com s3 cp file.txt s3://my-bucket/file.txt"

  def mount(_params, session, socket) do
    user =
      case session do
        %{"user_id" => id} -> Keeplix.Accounts.get_user(id)
        _ -> nil
      end

    {:ok, socket |> assign(:current_user, user) |> assign(:aws_example, @aws_example)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <h1 class="text-3xl font-bold text-slate-900 dark:text-slate-100">{gettext("Help")}</h1>
      <p class="mt-1 text-sm font-medium text-slate-700 dark:text-slate-300">
        {gettext("keeplix speaks S3 (path style) and offers a browser UI on top.")}
      </p>

      <section class="mt-6 rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-5 shadow-sm">
        <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">
          {gettext("Connect an S3 client")}
        </h2>
        <p class="mt-1 text-sm text-slate-700 dark:text-slate-300">
          {gettext(
            "Endpoint is this server, bucket and key go in the path. Create credentials under:"
          )}
          <.link
            navigate="/app/keys"
            class="font-semibold underline"
          >{gettext("Access keys")}</.link>
        </p>
        <pre class="mt-3 overflow-x-auto rounded-lg bg-slate-900 p-4 font-mono text-xs text-slate-100">{@aws_example}</pre>
      </section>

      <section class="mt-4 rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-5 shadow-sm">
        <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">{gettext("Share links")}</h2>
        <p class="mt-1 text-sm text-slate-700 dark:text-slate-300">
          {gettext(
            "Use “Share” on any object to create a time-limited download link (1 hour, 1 day or 7 days). Anyone with the link can download until it expires. Rotating or deleting your access keys invalidates outstanding links."
          )}
        </p>
      </section>

      <section class="mt-4 rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-5 shadow-sm">
        <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">{gettext("Versioning")}</h2>
        <p class="mt-1 text-sm text-slate-700 dark:text-slate-300">
          {gettext(
            "Buckets can keep every version of an object (enabled by an admin). Deleting then only hides the current version; older versions stay restorable until their version is deleted explicitly."
          )}
        </p>
      </section>

      <section class="mt-4 rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-5 shadow-sm">
        <h2 id="shortcuts" class="text-lg font-bold text-slate-900 dark:text-slate-100">
          {gettext("Keyboard shortcuts")}
        </h2>
        <dl class="mt-2 space-y-2 text-sm text-slate-700 dark:text-slate-300">
          <div class="flex items-center gap-3">
            <dt>
              <kbd class="rounded border border-slate-300 dark:border-slate-700 bg-slate-100 dark:bg-slate-800 px-2 py-0.5 font-mono font-bold">/</kbd>
            </dt>
            <dd>{gettext("Focus the object search in the bucket browser")}</dd>
          </div>
          <div class="flex items-center gap-3">
            <dt>
              <kbd class="rounded border border-slate-300 dark:border-slate-700 bg-slate-100 dark:bg-slate-800 px-2 py-0.5 font-mono font-bold">Esc</kbd>
            </dt>
            <dd>{gettext("Close dialogs, leave the search field")}</dd>
          </div>
        </dl>
      </section>
    </Layouts.app>
    """
  end
end
