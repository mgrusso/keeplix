defmodule KeeplixWeb.ProfileLive do
  use KeeplixWeb, :live_view

  alias Keeplix.{Accounts, Audit, WebAuthn}

  def mount(_params, session, socket) do
    user = get_user(session)

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:has_password, user != nil and not is_nil(user.password_hash))
     |> assign(:credentials, if(user, do: WebAuthn.list_credentials(user), else: []))
     |> assign(:backup_count, if(user, do: WebAuthn.remaining_backup_codes(user), else: 0))
     |> assign(
       :api_tokens,
       if(user && user.role == "admin", do: Accounts.list_api_tokens(user.id), else: [])
     )
     |> assign(:new_token, nil)
     |> assign(:new_codes, nil)
     |> assign(:challenge, nil)
     |> assign(:pending_label, nil)}
  end

  defp get_user(%{"user_id" => id}), do: Accounts.get_user(id)
  defp get_user(_), do: nil

  defp fresh_user(socket) do
    case socket.assigns.current_user do
      %{id: uid} -> Accounts.get_user(uid)
      _ -> nil
    end
  end

  defp refresh_2fa(socket, user) do
    socket
    |> assign(:credentials, WebAuthn.list_credentials(user))
    |> assign(:backup_count, WebAuthn.remaining_backup_codes(user))
    |> assign(:api_tokens, Accounts.list_api_tokens(user.id))
    |> assign(:new_codes, nil)
    |> assign(:challenge, nil)
    |> assign(:pending_label, nil)
  end

  def handle_event("save-password", params, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Please sign in first."))}

      user ->
        fresh = Accounts.get_user(user.id)

        case fresh && Accounts.update_own_password(fresh, params) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:current_user, updated)
             |> assign(:has_password, true)
             |> put_flash(:info, gettext("Password updated."))}

          {:error, :invalid_current} ->
            {:noreply, put_flash(socket, :error, gettext("Current password is wrong."))}

          {:error, :mismatch} ->
            {:noreply, put_flash(socket, :error, gettext("New passwords do not match."))}

          {:error, :too_short} ->
            {:noreply,
             put_flash(socket, :error, gettext("New password must have at least 8 characters."))}

          {:error, :pwned} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("This password has appeared in a data breach. Choose another one.")
             )}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Password update failed."))}
        end
    end
  end

  # ---------- passkeys ----------

  def handle_event("webauthn-begin", %{"label" => label}, socket) do
    case fresh_user(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Please sign in first."))}

      user ->
        challenge = WebAuthn.registration_challenge()

        {:noreply,
         socket
         |> assign(:challenge, challenge)
         |> assign(:pending_label, label)
         |> push_event("webauthn-register", %{
           challenge: Base.url_encode64(challenge.bytes, padding: false),
           rpId: challenge.rp_id,
           userId: Base.url_encode64(to_string(user.id), padding: false),
           userName: user.username,
           userDisplayName: user.display_name || user.username,
           excludeCredentials: Enum.map(WebAuthn.list_credentials(user), & &1.credential_id)
         })}
    end
  end

  def handle_event(
        "webauthn-registered",
        %{"id" => _raw_id, "attestation" => attestation, "clientData" => client_data},
        socket
      ) do
    user = fresh_user(socket)
    challenge = socket.assigns.challenge
    label = socket.assigns.pending_label
    socket = socket |> assign(:challenge, nil) |> assign(:pending_label, nil)

    cond do
      user == nil or challenge == nil ->
        {:noreply, put_flash(socket, :error, gettext("Registration expired. Try again."))}

      true ->
        case WebAuthn.verify_registration(user, label, attestation, client_data, challenge) do
          {:ok, _cred} ->
            Audit.log(user, "webauthn.register", user.username, %{})

            {:noreply,
             socket
             |> refresh_2fa(user)
             |> put_flash(:info, gettext("Passkey registered."))}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Registration failed (%{reason}).", reason: inspect(reason))
             )}
        end
    end
  end

  def handle_event("webauthn-error", %{"message" => message}, socket) do
    {:noreply,
     socket
     |> assign(:challenge, nil)
     |> assign(:pending_label, nil)
     |> put_flash(:error, gettext("Passkey failed: %{message}", message: message))}
  end

  def handle_event("webauthn-error", _, socket) do
    {:noreply,
     socket
     |> assign(:challenge, nil)
     |> assign(:pending_label, nil)
     |> put_flash(:info, gettext("Passkey cancelled."))}
  end

  def handle_event("rename-credential", %{"credential_id" => raw_id, "label" => label}, socket) do
    with %{id: _} = user <- fresh_user(socket),
         {id, ""} <- Integer.parse(to_string(raw_id)),
         {:ok, _} <- WebAuthn.rename_credential(user, id, label) do
      {:noreply, socket |> refresh_2fa(user) |> put_flash(:info, gettext("Passkey renamed."))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Not found."))}
    end
  end

  def handle_event("delete-credential", %{"credential_id" => raw_id}, socket) do
    with %{id: _} = user <- fresh_user(socket),
         {id, ""} <- Integer.parse(to_string(raw_id)),
         {:ok, _} <- WebAuthn.delete_credential(user, id) do
      Audit.log(user, "webauthn.delete", user.username, %{})
      {:noreply, socket |> refresh_2fa(user) |> put_flash(:info, gettext("Passkey removed."))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Not found."))}
    end
  end

  # ---------- backup codes ----------

  def handle_event("generate-codes", _, socket) do
    case fresh_user(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Please sign in first."))}

      user ->
        {:ok, codes} = WebAuthn.generate_backup_codes(user)
        Audit.log(user, "backup_codes.generate", user.username, %{})

        {:noreply,
         socket
         |> refresh_2fa(user)
         |> assign(:new_codes, codes)
         |> put_flash(:info, gettext("New backup codes generated. Old ones are invalid."))}
    end
  end

  def handle_event("save-locale", %{"locale" => locale}, socket)
      when locale in ["en", "de"] do
    case fresh_user(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Please sign in first."))}

      user ->
        case Accounts.update_user(user, %{"locale" => locale}) do
          {:ok, updated} ->
            Gettext.put_locale(KeeplixWeb.Gettext, locale)

            {:noreply,
             socket
             |> assign(:current_user, updated)
             |> assign(:locale, locale)
             |> put_flash(:info, gettext("Language updated."))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not save language."))}
        end
    end
  end

  def handle_event("save-locale", _, socket), do: {:noreply, socket}

  # ---------- API tokens (admins) ----------

  def handle_event("create-token", %{"name" => name}, socket) do
    case fresh_user(socket) do
      %{role: "admin"} = user ->
        case Accounts.create_api_token(user, String.trim(to_string(name || "api"))) do
          {:ok, record, plain} ->
            {:noreply,
             socket
             |> assign(:api_tokens, Accounts.list_api_tokens(user.id))
             |> assign(:new_token, %{id: record.id, name: record.name, token: plain})
             |> put_flash(
               :info,
               gettext("API token created. Copy it now – it will not be shown again.")
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not create API token."))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  def handle_event("revoke-token", %{"id" => raw_id}, socket) do
    case fresh_user(socket) do
      %{role: "admin"} = user ->
        with {id, ""} <- Integer.parse(to_string(raw_id)),
             :ok <- Accounts.revoke_api_token(user, id) do
          {:noreply,
           socket
           |> assign(:api_tokens, Accounts.list_api_tokens(user.id))
           |> put_flash(:info, gettext("API token revoked."))}
        else
          _ -> {:noreply, put_flash(socket, :error, gettext("Not found."))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized."))}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <h1 class="text-3xl font-bold text-slate-900 dark:text-slate-100">{gettext("Profile")}</h1>
      <p class="mt-1 text-sm font-medium text-slate-700 dark:text-slate-300">
        {gettext("Signed in as")}
        <span class="font-mono font-bold text-slate-900 dark:text-slate-100">{@current_user &&
          @current_user.username}</span>
        <span class="rounded-full bg-slate-100 dark:bg-slate-800 px-2 py-0.5 text-xs font-bold text-slate-900 dark:text-slate-100">{@current_user &&
          @current_user.role}</span>
      </p>

      <div class="mt-5 max-w-xl rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-5 shadow-sm">
        <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">{gettext("Language")}</h2>
        <form phx-submit="save-locale" id="locale-form" class="mt-3 flex flex-wrap items-end gap-2">
          <div>
            <label
              for="locale-select"
              class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
            >{gettext("Interface language")}</label>
            <select
              id="locale-select"
              name="locale"
              class="h-10 rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-3 text-sm text-slate-900 dark:text-slate-100"
            >
              <option value="en" selected={@locale != "de"}>English</option>
              <option value="de" selected={@locale == "de"}>Deutsch</option>
            </select>
          </div>
          <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">{gettext(
            "Save"
          )}</button>
        </form>
      </div>

      <%= if @current_user && @current_user.role == "admin" do %>
        <div class="mt-5 max-w-xl rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-5 shadow-sm">
          <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">
            {gettext("API tokens")}
          </h2>
          <p class="mt-1 text-sm text-slate-700 dark:text-slate-300">
            {gettext(
              "Personal tokens for the management API. Required when a passkey is enrolled (password logins are then rejected by the API)."
            )}
          </p>

          <%= if @new_token do %>
            <div class="mt-3 rounded-xl border-2 border-amber-500 dark:border-amber-800 bg-amber-50 dark:bg-amber-950 p-4">
              <p class="text-sm font-bold text-amber-900 dark:text-amber-200">
                {gettext("Copy now – it will not be shown again:")}
              </p>
              <p class="mt-1 break-all font-mono text-sm font-bold text-slate-900 dark:text-slate-100">
                {@new_token.token}
              </p>
            </div>
          <% end %>

          <%= if @api_tokens == [] do %>
            <p class="mt-3 text-sm font-medium text-slate-700 dark:text-slate-300">
              {gettext("No API tokens yet.")}
            </p>
          <% else %>
            <ul class="mt-3 space-y-2">
              <%= for t <- @api_tokens do %>
                <li class="flex flex-wrap items-center gap-2 rounded-lg border border-slate-200 dark:border-slate-700 px-3 py-2 text-sm">
                  <span class="font-mono font-bold text-slate-900 dark:text-slate-100">{t.name}</span>
                  <code class="rounded bg-slate-100 dark:bg-slate-800 px-1.5 py-0.5 font-mono text-xs text-slate-700 dark:text-slate-300">{t.prefix}…</code>
                  <button
                    phx-click="revoke-token"
                    phx-value-id={t.id}
                    data-confirm={gettext("Revoke this API token?")}
                    class="ml-auto h-8 rounded-lg border border-red-300 px-2 text-xs font-semibold text-red-700 hover:bg-red-50 dark:hover:bg-red-950"
                  >{gettext("Revoke")}</button>
                </li>
              <% end %>
            </ul>
          <% end %>

          <form
            phx-submit="create-token"
            id="token-form"
            class="mt-4 flex flex-wrap items-end gap-2 border-t border-slate-200 dark:border-slate-700 pt-4"
          >
            <div>
              <label
                for="token-name"
                class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
              >{gettext("New token name")}</label>
              <input
                id="token-name"
                name="name"
                placeholder={gettext("e.g. deploy script")}
                class="h-10 w-56 rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm"
              />
            </div>
            <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">{gettext(
              "Create token"
            )}</button>
          </form>
        </div>
      <% end %>

      <div class="mt-5 max-w-xl rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-5 shadow-sm">
        <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">
          {if @has_password, do: gettext("Change password"), else: gettext("Set password")}
        </h2>
        <%= if !@has_password do %>
          <p class="mt-1 text-sm text-slate-700 dark:text-slate-300">
            {gettext(
              "Your account uses single sign-on and has no password yet. Set one to enable password login."
            )}
          </p>
        <% end %>
        <form phx-submit="save-password" id="password-form" class="mt-4 space-y-3">
          <%= if @has_password do %>
            <div>
              <label
                for="current-password"
                class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
              >{gettext("Current password")}</label>
              <input
                id="current-password"
                name="current_password"
                type="password"
                autocomplete="current-password"
                class="h-10 w-full rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm text-slate-900 dark:text-slate-100"
              />
            </div>
          <% end %>
          <div>
            <label
              for="new-password"
              class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
            >{gettext("New password (min. 8 characters)")}</label>
            <input
              id="new-password"
              name="password"
              type="password"
              autocomplete="new-password"
              class="h-10 w-full rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm text-slate-900 dark:text-slate-100"
            />
          </div>
          <div>
            <label
              for="confirm-password"
              class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
            >{gettext("Confirm new password")}</label>
            <input
              id="confirm-password"
              name="password_confirmation"
              type="password"
              autocomplete="new-password"
              class="h-10 w-full rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm text-slate-900 dark:text-slate-100"
            />
          </div>
          <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">{gettext(
            "Save password"
          )}</button>
        </form>
      </div>

      <div class="mt-5 max-w-xl rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-5 shadow-sm">
        <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">{gettext("Passkeys")}</h2>
        <p class="mt-1 text-sm text-slate-700 dark:text-slate-300">
          {gettext(
            "Passwordless second factor for this account. Works with platform authenticators and security keys."
          )}
        </p>

        <%= if @credentials == [] do %>
          <p class="mt-3 text-sm font-medium text-slate-700 dark:text-slate-300">
            {gettext("No passkeys registered.")}
          </p>
        <% else %>
          <ul class="mt-3 space-y-2">
            <%= for cred <- @credentials do %>
              <li class="flex flex-wrap items-center gap-2 rounded-lg border border-slate-200 dark:border-slate-700 px-3 py-2 text-sm">
                <span class="font-mono font-bold text-slate-900 dark:text-slate-100">{cred.label}</span>
                <span class="text-xs font-medium text-slate-600 dark:text-slate-400">
                  {if cred.last_used_at,
                    do:
                      gettext("last used %{date}",
                        date: Calendar.strftime(cred.last_used_at, "%Y-%m-%d")
                      ),
                    else: gettext("never used")}
                </span>
                <form phx-submit="rename-credential" class="ml-auto flex items-center gap-1">
                  <input type="hidden" name="credential_id" value={cred.id} />
                  <input
                    type="text"
                    name="label"
                    value={cred.label}
                    aria-label={gettext("Rename passkey")}
                    class="h-8 w-28 rounded-lg border border-slate-300 dark:border-slate-700 px-2 text-xs"
                  />
                  <button class="h-8 rounded-lg border border-slate-300 dark:border-slate-700 px-2 text-xs font-semibold">{gettext(
                    "Rename"
                  )}</button>
                </form>
                <button
                  phx-click="delete-credential"
                  phx-value-credential-id={cred.id}
                  data-confirm={gettext("Remove this passkey?")}
                  class="h-8 rounded-lg border border-red-300 px-2 text-xs font-semibold text-red-700 hover:bg-red-50 dark:hover:bg-red-950"
                >{gettext("Remove")}</button>
              </li>
            <% end %>
          </ul>
        <% end %>

        <form
          phx-submit="webauthn-begin"
          id="passkey-form"
          class="mt-4 flex flex-wrap items-end gap-2 border-t border-slate-200 dark:border-slate-700 pt-4"
        >
          <div>
            <label
              for="passkey-label"
              class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
            >{gettext("New passkey name")}</label>
            <input
              id="passkey-label"
              name="label"
              placeholder={gettext("e.g. laptop")}
              class="h-10 w-56 rounded-lg border border-slate-300 dark:border-slate-700 px-3 text-sm"
            />
          </div>
          <button class="h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300">{gettext(
            "Add passkey"
          )}</button>
        </form>
        <div id="webauthn-register" phx-hook=".WebAuthnRegister" phx-update="ignore" class="hidden" />
      </div>

      <div class="mt-5 max-w-xl rounded-xl border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 p-5 shadow-sm">
        <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">
          {gettext("Backup codes")}
        </h2>
        <p class="mt-1 text-sm text-slate-700 dark:text-slate-300">
          {gettext("One-time codes for when your passkeys are unavailable. %{count} remaining.",
            count: @backup_count
          )}
        </p>
        <%= if @new_codes do %>
          <div class="mt-3 rounded-xl border-2 border-amber-500 bg-amber-50 dark:bg-amber-950 p-4">
            <p class="text-sm font-bold text-amber-900 dark:text-amber-200">
              {gettext("Copy now – shown only once:")}
            </p>
            <ul class="mt-2 grid grid-cols-2 gap-1 font-mono text-sm font-bold text-slate-900 dark:text-slate-100">
              <%= for code <- @new_codes do %>
                <li>{code}</li>
              <% end %>
            </ul>
          </div>
        <% end %>
        <button
          phx-click="generate-codes"
          data-confirm={gettext("Generate new codes? Old ones stop working.")}
          class="mt-3 h-10 rounded-lg bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300"
        >{gettext("Generate new codes")}</button>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".WebAuthnRegister">
        export default {
          mounted() {
            this.handleEvent("webauthn-register", (opts) => this.register(opts));
          },
          async register({challenge, rpId, userId, userName, userDisplayName, excludeCredentials}) {
            try {
              if (!window.PublicKeyCredential) throw new Error("unsupported");
              const publicKey = {
                challenge: b64ToBytes(challenge),
                rp: {name: "Keeplix", id: rpId},
                user: {id: b64ToBytes(userId), name: userName, displayName: userDisplayName},
                pubKeyCredParams: [{type: "public-key", alg: -7}, {type: "public-key", alg: -257}],
                timeout: 120000,
                attestation: "none",
                authenticatorSelection: {userVerification: "preferred"}
              };
              if (excludeCredentials && excludeCredentials.length > 0) {
                publicKey.excludeCredentials = excludeCredentials.map((id) => ({type: "public-key", id: b64ToBytes(id)}));
              }
              const cred = await navigator.credentials.create({publicKey});
              this.pushEvent("webauthn-registered", {
                id: cred.id,
                attestation: bytesToB64(new Uint8Array(cred.response.attestationObject)),
                clientData: bytesToB64(new Uint8Array(cred.response.clientDataJSON))
              });
            } catch (e) {
              this.pushEvent("webauthn-error", {message: (e && e.message) || "failed"});
            }
          }
        };
        function b64ToBytes(b64) {
          const bin = atob(b64.replace(/-/g, "+").replace(/_/g, "/"));
          const bytes = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          return bytes;
        }
        function bytesToB64(bytes) {
          let bin = "";
          bytes.forEach((b) => { bin += String.fromCharCode(b); });
          return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
        }
      </script>
    </Layouts.app>
    """
  end
end
