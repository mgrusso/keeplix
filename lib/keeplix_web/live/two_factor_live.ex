defmodule KeeplixWeb.TwoFactorLive do
  @moduledoc """
  Second login step: passkey challenge (WebAuthn ceremony via a colocated
  hook) or a one-time backup code. Reached only with a pending password
  login in the session.
  """
  use KeeplixWeb, :live_view

  alias Keeplix.{Accounts, Audit, RateLimit, WebAuthn}

  def mount(_params, session, socket) do
    cond do
      session["user_id"] || session[:user_id] ->
        # Already fully logged in.
        {:ok,
         push_navigate(socket |> assign(:current_user, nil) |> assign(:pending_user, nil),
           to: "/app"
         )}

      true ->
        user =
          case session["pending_2fa_user_id"] || session[:pending_2fa_user_id] do
            nil -> nil
            uid -> Accounts.get_user(uid)
          end

        user = if user && user.is_active, do: user

        if user && WebAuthn.second_factor_required?(user) do
          {:ok,
           socket
           |> assign(:current_user, nil)
           |> assign(:pending_user, user)
           |> assign(:challenge, nil)}
        else
          {:ok,
           socket
           |> assign(:current_user, nil)
           |> assign(:pending_user, nil)
           |> push_navigate(to: "/login")}
        end
    end
  end

  defp rate_key(%Accounts.User{username: username}) do
    username |> String.trim() |> String.downcase()
  rescue
    _ -> "invalid"
  end

  def handle_event("begin", _, socket) do
    user = socket.assigns.pending_user

    cond do
      user == nil ->
        {:noreply, push_navigate(socket, to: "/login")}

      RateLimit.check(:login_user, rate_key(user)) == :blocked ->
        {:noreply, put_flash(socket, :error, "Too many failed attempts. Try again later.")}

      true ->
        challenge = WebAuthn.authentication_challenge(user)

        {:noreply,
         socket
         |> assign(:challenge, challenge)
         |> push_event("webauthn-authenticate", %{
           challenge: Base.url_encode64(challenge.bytes, padding: false),
           rpId: challenge.rp_id,
           allowCredentials: Enum.map(challenge.allow_credentials, fn {id, _} -> id end)
         })}
    end
  end

  def handle_event(
        "verify",
        %{"id" => raw_id, "authData" => auth, "signature" => sig, "clientData" => client_data},
        socket
      ) do
    user = socket.assigns.pending_user
    challenge = socket.assigns.challenge
    socket = assign(socket, :challenge, nil)

    cond do
      user == nil or challenge == nil ->
        {:noreply, push_navigate(socket, to: "/login")}

      true ->
        case WebAuthn.verify_authentication(user, raw_id, auth, sig, client_data, challenge) do
          {:ok, user} ->
            complete_login(socket, user)

          {:error, _} ->
            RateLimit.track_failure(:login_user, rate_key(user))
            Audit.log(nil, "auth.failed_2fa", user.username, %{})
            {:noreply, put_flash(socket, :error, "Passkey verification failed.")}
        end
    end
  end

  def handle_event("use-backup-code", %{"code" => code}, socket) do
    user = socket.assigns.pending_user

    cond do
      user == nil ->
        {:noreply, push_navigate(socket, to: "/login")}

      RateLimit.check(:login_user, rate_key(user)) == :blocked ->
        {:noreply, put_flash(socket, :error, "Too many failed attempts. Try again later.")}

      true ->
        case WebAuthn.verify_backup_code(user, code) do
          {:ok, :used} ->
            Audit.log(user, "auth.backup_code", user.username, %{})
            complete_login(socket, user)

          {:error, _} ->
            RateLimit.track_failure(:login_user, rate_key(user))
            {:noreply, put_flash(socket, :error, "Invalid backup code.")}
        end
    end
  end

  def handle_event("webauthn-error", %{"message" => message}, socket) do
    {:noreply, put_flash(socket, :error, "Passkey failed: #{message}")}
  end

  def handle_event("webauthn-error", _, socket) do
    {:noreply, put_flash(socket, :error, "Passkey failed.")}
  end

  defp complete_login(socket, user) do
    # LiveViews cannot write the Plug session; hand a single-use token to
    # the controller finish endpoint, which establishes the session.
    token = Keeplix.LoginTokens.issue(user.id)
    {:noreply, redirect(socket, to: "/login/2fa/finish?token=#{token}")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto w-full max-w-md rounded-2xl border border-slate-300 bg-white p-8 shadow-sm dark:border-slate-700 dark:bg-slate-900">
        <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">
          Two-factor authentication
        </h1>
        <p class="mt-1 text-sm font-medium text-slate-700 dark:text-slate-300">
          Signed in as <span class="font-mono font-bold">{@pending_user && @pending_user.username}</span>.
          Confirm with your passkey or a backup code.
        </p>

        <div class="mt-5 space-y-3">
          <button
            phx-click="begin"
            id="webauthn-begin"
            class="h-11 w-full rounded-lg bg-slate-900 text-base font-semibold text-white hover:bg-slate-700 dark:bg-slate-100 dark:text-slate-900 dark:hover:bg-slate-300"
          >Use passkey</button>

          <form
            phx-submit="use-backup-code"
            id="backup-code-form"
            class="space-y-3 border-t border-slate-200 pt-4 dark:border-slate-700"
          >
            <div>
              <label
                for="backup-code"
                class="mb-1 block text-sm font-semibold text-slate-900 dark:text-slate-100"
              >Backup code</label>
              <input
                id="backup-code"
                name="code"
                autocomplete="one-time-code"
                placeholder="xxxx-xxxx"
                class="h-11 w-full rounded-lg border border-slate-300 bg-white px-3 font-mono text-base text-slate-900 placeholder:text-slate-500 dark:border-slate-700 dark:bg-slate-900 dark:text-slate-100 dark:placeholder:text-slate-400"
              />
            </div>
            <button class="h-11 w-full rounded-lg border border-slate-300 px-4 text-sm font-semibold text-slate-900 hover:bg-slate-100 dark:border-slate-700 dark:text-slate-100 dark:hover:bg-slate-800">Use backup code</button>
          </form>
        </div>
      </div>

      <div
        id="webauthn-authenticate"
        phx-hook=".WebAuthnAuthenticate"
        phx-update="ignore"
        class="hidden"
      />
      <script :type={Phoenix.LiveView.ColocatedHook} name=".WebAuthnAuthenticate">
        export default {
          mounted() {
            this.handleEvent("webauthn-authenticate", (opts) => this.authenticate(opts));
          },
          async authenticate({challenge, rpId, allowCredentials}) {
            try {
              if (!window.PublicKeyCredential) throw new Error("unsupported");
              const cred = await navigator.credentials.get({
                publicKey: {
                  challenge: b64ToBytes(challenge),
                  rpId: rpId,
                  allowCredentials: (allowCredentials || []).map((id) => ({type: "public-key", id: b64ToBytes(id)})),
                  userVerification: "preferred",
                  timeout: 120000
                }
              });
              this.pushEvent("verify", {
                id: cred.id,
                authData: bytesToB64(new Uint8Array(cred.response.authenticatorData)),
                signature: bytesToB64(new Uint8Array(cred.response.signature)),
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
