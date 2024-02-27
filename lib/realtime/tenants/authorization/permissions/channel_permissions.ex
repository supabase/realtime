defmodule Realtime.Tenants.Authorization.Permissions.ChannelPermissions do
  @moduledoc """
  ChannelPermissions structure that holds the required authorization information for a given connection within the scope of a reading / altering channel entities

  Uses the Realtime.Api.Channel to try reads and writes on the database to determine authorization for a given connection.

  > Note: Currently we only allow permissions to read all but not write all IF the RLS policies allow it.

  Implements Realtime.Tenants.Authorization behaviour.
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
  def check_read_permissions(conn, %Permissions{} = permissions, %Authorization{channel: nil}) do
    case Repo.all(conn, Channel, Channel, mode: :savepoint) do
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

  def check_read_permissions(conn, %Permissions{} = permissions, %Authorization{channel: channel}) do
    query = from(c in Channel, where: c.id == ^channel.id)

    case Repo.one(conn, query, Channel) do
      {:ok, channels} when channels != [] ->
        permissions = Permissions.update_permissions(permissions, :channel, :read, true)
        {:ok, permissions}

      {:ok, _} ->
        permissions = Permissions.update_permissions(permissions, :channel, :read, false)
        {:ok, permissions}

      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
        permissions = Permissions.update_permissions(permissions, :channel, :read, false)
        {:ok, permissions}

      {:error, :not_found} ->
        permissions = Permissions.update_permissions(permissions, :channel, :read, false)

        {:ok, permissions}

      {:error, error} ->
        Logger.error("Error getting permissions for connection: #{inspect(error)}")
        {:error, error}
    end
  end

  @impl true
  def check_write_permissions(_conn, permissions, %Authorization{channel: nil}) do
    {:ok, Permissions.update_permissions(permissions, :channel, :write, false)}
  end

  def check_write_permissions(conn, permissions, %Authorization{channel: channel}) do
    changeset = Channel.check_changeset(channel, %{check: true})

    case Repo.update(conn, changeset, Channel, mode: :savepoint) do
      {:ok, %Channel{check: true} = channel} ->
        revert_changeset = Channel.check_changeset(channel, %{check: false})
        {:ok, _} = Repo.update(conn, revert_changeset, Channel)
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
