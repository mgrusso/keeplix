defmodule Keeplix.WebAuthnTest do
  @moduledoc """
  Passkey ceremonies against a virtual authenticator (real ES256 crypto,
  no browser needed) plus backup-code flows (Phase A).
  """
  use Keeplix.DataCase

  alias Keeplix.{Accounts, Repo, WebAuthn}
  alias Keeplix.WebAuthn.Credential

  # Always mirror the relying party under test (endpoint-derived).
  defp origin, do: WebAuthn.origin()
  defp rp_id, do: WebAuthn.rp_id()

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        username: "wa-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    {:ok, user: user}
  end

  # ---------- virtual authenticator ----------

  defp gen_keypair do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    <<4, x::binary-32, y::binary-32>> = pub
    {%{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}, priv}
  end

  defp client_data(type, challenge) do
    Jason.encode!(%{
      "type" => type,
      "challenge" => Base.url_encode64(challenge.bytes, padding: false),
      "origin" => origin()
    })
  end

  defp auth_data(cred_id, sign_count), do: auth_data(cred_id, sign_count, nil)

  defp auth_data(cred_id, sign_count, cose) do
    rp_hash = :crypto.hash(:sha256, rp_id())
    flags = if cred_id, do: 0x41, else: 0x01
    base = rp_hash <> <<flags, sign_count::32>>

    if cred_id do
      base <> <<0::128>> <> <<byte_size(cred_id)::16>> <> cred_id <> CBOR.encode(cose)
    else
      base
    end
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp register(user, label \\ "test key") do
    challenge = WebAuthn.registration_challenge()
    cred_id = :crypto.strong_rand_bytes(16)
    {cose, priv} = gen_keypair()
    authd = auth_data(cred_id, 0, cose)
    client_json = client_data("webauthn.create", challenge)
    att_obj = CBOR.encode(%{"fmt" => "none", "authData" => authd, "attStmt" => %{}})

    {:ok, cred} = WebAuthn.verify_registration(user, label, b64(att_obj), client_json, challenge)
    {cred, priv}
  end

  defp assert_auth(user, cred, priv, sign_count) do
    challenge = WebAuthn.authentication_challenge(user)
    authd = auth_data(nil, sign_count)
    client_json = client_data("webauthn.get", challenge)

    sig =
      :crypto.sign(:ecdsa, :sha256, authd <> :crypto.hash(:sha256, client_json), [
        priv,
        :secp256r1
      ])

    assert {:ok, _} =
             WebAuthn.verify_authentication(
               user,
               cred.credential_id,
               b64(authd),
               b64(sig),
               client_json,
               challenge
             )
  end

  # ---------- registration ----------

  test "registration stores credential, key and counter", %{user: user} do
    {cred, _priv} = register(user)

    assert cred.sign_count == 0
    assert is_binary(cred.aaguid)

    stored = Repo.get!(Credential, cred.id)
    assert stored.user_id == user.id

    assert {:ok, key} =
             stored.public_key
             |> Base.decode64()
             |> then(fn {:ok, b} -> {:ok, :erlang.binary_to_term(b, [:safe])} end)

    assert is_map(key)
  end

  test "duplicate credential ids are rejected across users", %{user: user} do
    # Same authenticator, same credential id, second user.
    challenge = WebAuthn.registration_challenge()
    {cose, _} = gen_keypair()
    cred_id = :crypto.strong_rand_bytes(16)
    authd = auth_data(cred_id, 0, cose)
    client_json = client_data("webauthn.create", challenge)
    att_obj = CBOR.encode(%{"fmt" => "none", "authData" => authd, "attStmt" => %{}})
    att_b64 = b64(att_obj)

    {:ok, _} = WebAuthn.verify_registration(user, "first", att_b64, client_json, challenge)

    {:ok, other} =
      Accounts.create_user(%{
        username: "wa2-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    challenge2 = WebAuthn.registration_challenge()
    client_json2 = client_data("webauthn.create", challenge2)
    att_obj2 = CBOR.encode(%{"fmt" => "none", "authData" => authd, "attStmt" => %{}})

    assert {:error, :already_registered} =
             WebAuthn.verify_registration(
               other,
               "second",
               b64(att_obj2),
               client_json2,
               challenge2
             )
  end

  test "wrong origin is rejected", %{user: user} do
    challenge = WebAuthn.registration_challenge()
    {cose, _} = gen_keypair()
    authd = auth_data(:crypto.strong_rand_bytes(16), 0, cose)

    evil_json =
      Jason.encode!(%{
        "type" => "webauthn.create",
        "challenge" => Base.url_encode64(challenge.bytes, padding: false),
        "origin" => "https://evil.example.com"
      })

    att_obj = CBOR.encode(%{"fmt" => "none", "authData" => authd, "attStmt" => %{}})

    assert {:error, _} =
             WebAuthn.verify_registration(user, "x", b64(att_obj), evil_json, challenge)
  end

  # ---------- authentication ----------

  test "assertion verifies and advances the counter", %{user: user} do
    {cred, priv} = register(user)
    assert_auth(user, cred, priv, 1)
    assert Repo.get!(Credential, cred.id).sign_count == 1
    assert_auth(user, cred, priv, 2)
    assert Repo.get!(Credential, cred.id).sign_count == 2
  end

  test "tampered payload fails verification", %{user: user} do
    {cred, priv} = register(user)
    challenge = WebAuthn.authentication_challenge(user)
    authd = auth_data(nil, 1)
    client_json = client_data("webauthn.get", challenge)

    sig =
      :crypto.sign(:ecdsa, :sha256, authd <> :crypto.hash(:sha256, client_json), [
        priv,
        :secp256r1
      ])

    <<head::binary-10, flip, rest::binary>> = authd
    tampered = head <> <<Bitwise.bxor(flip, 0xFF)>> <> rest

    assert {:error, _} =
             WebAuthn.verify_authentication(
               user,
               cred.credential_id,
               b64(tampered),
               b64(sig),
               client_json,
               challenge
             )
  end

  test "sign-count regression signals possible clone", %{user: user} do
    {cred, priv} = register(user)
    assert_auth(user, cred, priv, 5)

    challenge = WebAuthn.authentication_challenge(user)
    authd = auth_data(nil, 3)
    client_json = client_data("webauthn.get", challenge)

    sig =
      :crypto.sign(:ecdsa, :sha256, authd <> :crypto.hash(:sha256, client_json), [
        priv,
        :secp256r1
      ])

    assert {:error, :possible_clone} =
             WebAuthn.verify_authentication(
               user,
               cred.credential_id,
               b64(authd),
               b64(sig),
               client_json,
               challenge
             )
  end

  # ---------- management ----------

  test "rename and delete are scoped to the owner", %{user: user} do
    {cred, _} = register(user, "old name")
    assert {:ok, renamed} = WebAuthn.rename_credential(user, cred.id, "laptop")
    assert renamed.label == "laptop"

    {:ok, other} =
      Accounts.create_user(%{
        username: "wa3-#{System.unique_integer([:positive])}",
        password: "secret1234",
        role: "user"
      })

    assert {:error, :not_found} = WebAuthn.rename_credential(other, cred.id, "x")
    assert {:error, :not_found} = WebAuthn.delete_credential(other, cred.id)
    assert {:ok, _} = WebAuthn.delete_credential(user, cred.id)
    assert WebAuthn.list_credentials(user) == []
  end

  # ---------- backup codes ----------

  test "backup codes are single-use and regenerable", %{user: user} do
    {:ok, codes} = WebAuthn.generate_backup_codes(user)
    assert length(codes) == 10
    assert WebAuthn.remaining_backup_codes(user) == 10

    [first | _] = codes
    assert {:ok, :used} = WebAuthn.verify_backup_code(user, first)
    assert {:error, :invalid_code} = WebAuthn.verify_backup_code(user, first)
    assert {:error, :invalid_code} = WebAuthn.verify_backup_code(user, "nope-nope")
    assert WebAuthn.remaining_backup_codes(user) == 9

    {:ok, fresh} = WebAuthn.generate_backup_codes(user)
    assert WebAuthn.remaining_backup_codes(user) == 10
    assert {:error, :invalid_code} = WebAuthn.verify_backup_code(user, first)
    assert {:ok, :used} = WebAuthn.verify_backup_code(user, hd(fresh))
  end
end
