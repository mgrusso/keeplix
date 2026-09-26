defmodule Keeplix.Audit do
  @moduledoc """
  Best-effort audit trail for security-relevant actions (user/key/grant/
  bucket administration, key self-service).

  Logging never crashes the caller: failures are swallowed.
  """
  import Ecto.Query

  alias Keeplix.Repo
  alias Keeplix.Audit.Event
  alias Keeplix.Accounts.User

  @spec log(User.t() | nil, String.t(), String.t() | nil, map()) :: :ok
  def log(actor, action, target \\ nil, meta \\ %{}) do
    {actor_id, actor_username} =
      case actor do
        %User{id: id, username: username} -> {id, username}
        _ -> {nil, nil}
      end

    %Event{}
    |> Event.changeset(%{
      actor_id: actor_id,
      actor_username: actor_username,
      action: action,
      target: target,
      meta: Jason.encode!(meta)
    })
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  @spec list_recent(pos_integer()) :: [Event.t()]
  def list_recent(limit \\ 100) do
    Repo.all(from e in Event, order_by: [desc: e.inserted_at, desc: e.id], limit: ^limit)
  end
end
