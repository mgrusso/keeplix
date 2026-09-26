defmodule KeeplixWeb.Api.BucketController do
  @moduledoc """
  Management API: buckets (admin only, HTTP Basic).
  """
  use KeeplixWeb, :controller

  alias Keeplix.{Accounts, Audit, Buckets, RateLimit}

  action_fallback KeeplixWeb.Api.FallbackController

  def index(conn, _params) do
    json(conn, %{buckets: Enum.map(Buckets.list_buckets(), &render_bucket/1)})
  end

  def show(conn, %{"name" => name}) do
    with %Buckets.Bucket{} = bucket <- Buckets.get_bucket(name) do
      json(conn, %{bucket: render_bucket(bucket)})
    else
      nil -> {:error, :not_found}
    end
  end

  def create(conn, %{"name" => _} = params) do
    with {:ok, owner} <- find_owner(conn, params),
         {:ok, bucket} <- Buckets.create_bucket(params["name"], owner) do
      bucket = maybe_set_quota(bucket, params)
      audit(conn, "api.bucket.create", bucket.name, %{})
      conn |> put_status(201) |> json(%{bucket: render_bucket(bucket)})
    else
      {:error, :no_owner} -> {:error, :not_found}
      {:error, changeset} -> {:error, {:invalid, changeset}}
    end
  end

  def create(_conn, _params), do: {:error, {:invalid, missing_name()}}

  def update(conn, %{"name" => name} = params) do
    with %Buckets.Bucket{} = bucket <- Buckets.get_bucket(name),
         {:ok, bucket} <- apply_bucket_update(bucket, params) do
      audit(conn, "api.bucket.update", bucket.name, %{})
      json(conn, %{bucket: render_bucket(bucket)})
    else
      nil -> {:error, :not_found}
      {:error, :invalid_transition} -> {:error, {:invalid, transition_changeset()}}
      {:error, changeset} -> {:error, {:invalid, changeset}}
    end
  end

  def delete(conn, %{"name" => name}) do
    with %Buckets.Bucket{} = bucket <- Buckets.get_bucket(name),
         :ok <- Buckets.delete_bucket(bucket) do
      audit(conn, "api.bucket.delete", name, %{})
      send_resp(conn, 204, "")
    else
      nil -> {:error, :not_found}
      {:error, _} -> {:error, :conflict}
    end
  end

  defp find_owner(_conn, %{"owner" => username}) when is_binary(username) do
    case Accounts.get_user_by_username(username) do
      nil -> {:error, :no_owner}
      user -> {:ok, user}
    end
  end

  defp find_owner(conn, _), do: {:ok, conn.assigns.api_user}

  defp maybe_set_quota(bucket, %{"quota_bytes" => quota}) when is_integer(quota) and quota > 0 do
    case Buckets.update_bucket(bucket, %{quota_bytes: quota}) do
      {:ok, updated} -> updated
      _ -> bucket
    end
  end

  defp maybe_set_quota(bucket, _), do: bucket

  defp apply_bucket_update(bucket, %{"quota_bytes" => quota} = params) when is_integer(quota) do
    case Buckets.update_bucket(bucket, %{quota_bytes: quota}) do
      {:ok, updated} -> apply_versioning(updated, params)
      err -> err
    end
  end

  defp apply_bucket_update(bucket, params), do: apply_versioning(bucket, params)

  defp apply_versioning(bucket, %{"versioning" => mode}) when mode in ["enabled", "suspended"] do
    Buckets.set_versioning(bucket, mode)
  end

  defp apply_versioning(bucket, _), do: {:ok, bucket}

  defp render_bucket(b) do
    owner = if Ecto.assoc_loaded?(b.owner) and b.owner, do: b.owner.username, else: nil

    %{name: b.name, owner: owner, quota_bytes: b.quota_bytes, versioning: b.versioning}
  end

  defp missing_name do
    %Ecto.Changeset{}
    |> Ecto.Changeset.add_error(:name, "can't be blank")
  end

  defp transition_changeset do
    %Ecto.Changeset{}
    |> Ecto.Changeset.add_error(:versioning, "illegal transition")
  end

  defp audit(conn, action, target, details) do
    Audit.log(
      conn.assigns.api_user,
      action,
      target,
      Map.put(details, :ip, RateLimit.client_ip(conn))
    )
  end
end
