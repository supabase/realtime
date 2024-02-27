defmodule Realtime.Tenants.Authorization.Permissions.ChannelPermissions do
  @moduledoc """
  ChannelPermissions structure that holds the required authorization information for a given connection within the scope of a reading / altering channel entities

  Uses the Realtime.Api.Channel to try reads and writes on the database to determine authorization for a given connection.

  Implements Realtime.Tenants.Authorization behaviour
  """
  require Logger
  import Ecto.Query

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
  def build_permissions(permissions) do
    Map.put(permissions, :channel, %__MODULE__{})
  end

  @impl true
  def check_read_permissions(conn, %Permissions{} = permissions) do
    query = from(c in Channel, select: c.name)

    case Repo.all(conn, query, Channel, mode: :savepoint) do
      {:ok, channels} when channels != [] ->
        permissions = Permissions.update_permissions(permissions, :channel, :read, true)
        {:ok, permissions}

      {:ok, _} ->
        permissions = Permissions.update_permissions(permissions, :channel, :read, false)
        {:ok, permissions}

      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
        permissions = Permissions.update_permissions(permissions, :channel, :read, false)
        {:ok, permissions}

      {:error, error} ->
        Logger.error("Error getting permissions for connection: #{inspect(error)}")
        {:error, error}
    end
  end

  @impl true
  def check_write_permissions(_db_conn, permissions, %Authorization{channel: nil}) do
    {:ok, Permissions.update_permissions(permissions, :channel, :write, false)}
  end

  def check_write_permissions(db_conn, permissions, %Authorization{channel: channel}) do
    changeset = Channel.check_changeset(channel, %{check: true})

    case Repo.update(db_conn, changeset, Channel, mode: :savepoint) do
      {:ok, %Channel{check: true} = channel} ->
        revert_changeset = Channel.check_changeset(channel, %{check: nil})
        {:ok, _} = Repo.update(db_conn, revert_changeset, Channel)
        permissions = Permissions.update_permissions(permissions, :channel, :write, true)

        {:ok, permissions}

      {:ok, _} ->
        permissions = Permissions.update_permissions(permissions, :channel, :write, false)
        {:ok, permissions}

      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
        permissions = Permissions.update_permissions(permissions, :channel, :write, false)
        {:ok, permissions}

      {:error, :not_found} ->
        permissions = Permissions.update_permissions(permissions, :channel, :write, false)

        {:ok, permissions}

      {:error, error} ->
        Logger.error("Error getting permissions for connection: #{inspect(error)}")
        {:error, error}
    end
  end
end
