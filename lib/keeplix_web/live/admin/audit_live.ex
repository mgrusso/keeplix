defmodule KeeplixWeb.Admin.AuditLive do
  use KeeplixWeb, :live_view

  alias Keeplix.{Accounts, Audit}

  def mount(_params, session, socket) do
    user = get_user(session)

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:events, Audit.list_recent(100))}
  end

  defp get_user(%{"user_id" => id}), do: Accounts.get_user(id)
  defp get_user(_), do: nil

  defp format_time(nil), do: "—"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp format_time(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> format_time()

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <h1 class="text-3xl font-bold text-slate-900 dark:text-slate-100">Audit log</h1>
      <p class="mt-1 text-sm font-medium text-slate-700 dark:text-slate-300">
        Latest 100 security-relevant actions.
      </p>

      <div class="mt-5 overflow-x-auto rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 shadow-sm">
        <table class="w-full text-left text-sm">
          <thead class="bg-slate-100 dark:bg-slate-800 text-xs font-bold uppercase tracking-wide text-slate-800 dark:text-slate-200">
            <tr>
              <th class="px-4 py-3">Time (UTC)</th><th class="px-4 py-3">Actor</th><th class="px-4 py-3">
                Action
              </th><th class="px-4 py-3">Target</th>
            </tr>
          </thead>
          <tbody>
            <%= if @events == [] do %>
              <tr>
                <td
                  colspan="4"
                  class="px-4 py-6 text-center font-medium text-slate-700 dark:text-slate-300"
                >
                  No audit events yet.
                </td>
              </tr>
            <% else %>
              <%= for e <- @events do %>
                <tr class="border-t border-slate-200 dark:border-slate-700">
                  <td class="whitespace-nowrap px-4 py-2.5 font-mono text-xs text-slate-800 dark:text-slate-200">
                    {format_time(e.inserted_at)}
                  </td>
                  <td class="px-4 py-2.5 font-semibold text-slate-900 dark:text-slate-100">
                    {e.actor_username || "system"}
                  </td>
                  <td class="px-4 py-2.5">
                    <span class="rounded-full bg-slate-100 dark:bg-slate-800 px-2.5 py-1 text-xs font-bold text-slate-900 dark:text-slate-100">{e.action}</span>
                  </td>
                  <td class="break-all px-4 py-2.5 font-mono text-xs text-slate-800 dark:text-slate-200">
                    {e.target}
                  </td>
                </tr>
              <% end %>
            <% end %>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
