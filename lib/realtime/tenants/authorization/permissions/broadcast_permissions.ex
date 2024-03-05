defmodule Realtime.Tenants.Authorization.Permissions.BroadcastPermissions do
  @moduledoc """
  ChannelPermissions structure that holds the required authorization information for a given connection within the scope of a reading / altering channel entities

  Uses the Realtime.Api.Channel to try reads and writes on the database to determine authorization for a given connection.

  Implements Realtime.Tenants.Authorization behaviour
  """
  require Logger
  import Ecto.Query

  alias Realtime.Api.Broadcast
  alias Realtime.Api.Channel
  alias Realtime.Repo
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Permissions

  defstruct read: false, write: false

  @behaviour Realtime.Tenants.Authorization.Permissions

  @type t :: %__MODULE__{
          :read => boolean(),
          :write => boolean()
        }
  @impl true
  def check_read_permissions(_conn, permissions, %Authorization{channel: nil}) do
    {:ok, Permissions.update_permissions(permissions, :broadcast, :read, false)}
  end

  def check_read_permissions(conn, %Permissions{} = permissions, %Authorization{
        channel: %Channel{id: channel_id}
      }) do
    query = from(b in Broadcast, where: b.channel_id == ^channel_id)

    Postgrex.transaction(conn, fn transaction_conn ->
      case Repo.one(conn, query, Broadcast) do
        {:ok, %Broadcast{}} ->
          Permissions.update_permissions(permissions, :broadcast, :read, true)

        {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
          Permissions.update_permissions(permissions, :broadcast, :read, false)

        {:error, :not_found} ->
          Permissions.update_permissions(permissions, :broadcast, :read, false)

        {:error, error} ->
          Logger.error(
            "Error getting broadcast read permissions for connection: #{inspect(error)}"
          )

          Postgrex.rollback(transaction_conn, error)
      end
    end)
  end

  @impl true
  def check_write_permissions(_conn, permissions, %Authorization{channel: nil}) do
    {:ok, Permissions.update_permissions(permissions, :broadcast, :write, false)}
  end

  def check_write_permissions(conn, permissions, %Authorization{
        channel: %Channel{id: channel_id}
      }) do
    query = from(b in Broadcast, where: b.channel_id == ^channel_id)

    Postgrex.transaction(conn, fn transaction_conn ->
      case Repo.one(conn, query, Broadcast) do
        {:ok, %Broadcast{} = broadcast} ->
          changeset = Broadcast.check_changeset(broadcast, %{check: true})

          case Repo.update(conn, changeset, Broadcast, mode: :savepoint) do
            {:ok, %Broadcast{check: true} = broadcast} ->
              revert_changeset = Broadcast.check_changeset(broadcast, %{check: false})
              {:ok, _} = Repo.update(conn, revert_changeset, Broadcast)
              Permissions.update_permissions(permissions, :broadcast, :write, true)

            {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
              Permissions.update_permissions(permissions, :broadcast, :write, false)

            {:error, :not_found} ->
              Permissions.update_permissions(permissions, :broadcast, :write, false)

            {:error, error} ->
              Logger.error(
                "Error getting broadcast write permissions for connection: #{inspect(error)}"
              )

              Postgrex.rollback(transaction_conn, error)
          end

        {:error, :not_found} ->
          Permissions.update_permissions(permissions, :broadcast, :write, false)
      end
    end)
  end
end
