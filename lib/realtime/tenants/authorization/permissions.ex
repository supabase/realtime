defmodule Realtime.Tenants.Authorization.Permissions do
  @moduledoc """
  Permissions structure that holds the required authorization information for a given connection.

  Also defines a behaviour to be used by the different authorization modules to build and check permissions within the context of an entity.

  Currently there are two types of permissions:
  * Realtime.Tenants.Authorization.Permissions.BroadcastPermissions - Used to check access to the Channel itself
  * Realtime.Tenants.Authorization.Permissions.ChannelPermissions - Used to check access to the Broadcast feature on a given Channel
  """

  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Permissions.BroadcastPermissions
  alias Realtime.Tenants.Authorization.Permissions.ChannelPermissions
  defstruct channel: %ChannelPermissions{}, broadcast: %BroadcastPermissions{}

  @type t :: %__MODULE__{channel: ChannelPermissions.t(), broadcast: BroadcastPermissions.t()}

  @doc """
  Implementation of the method on how to check read permissions for a given entity within the context of a database connection

  Arguments:
    * `db_conn` - The database connection with the required context to properly run checks
    * `permissions` - The permissions struct to which the result will be accumulated
    * `authorization` - The authorization struct with required information for permission checking
  """
  @callback check_read_permissions(DBConnection.t(), t(), Authorization.t()) ::
              {:ok, t()} | {:error, any()}
  @doc """
  Implementation of the method on how to check write permissions for a given entity within the context of a database connection

  Arguments:
    * `db_conn` - The database connection with the required context to properly run checks
    * `permissions` - The permissions struct to which the result will be accumulated
    * `authorization` - The authorization struct with required information for permission checking
  """
  @callback check_write_permissions(DBConnection.t(), t(), Authorization.t()) ::
              {:ok, t()} | {:error, any()}

  @doc """
  Updates the Permission struct sub key with the given value.
  """
  @spec update_permissions(t(), atom, atom, boolean) :: t()
  def update_permissions(permissions, key, sub_key, value) do
    Map.update!(permissions, key, fn map -> Map.put(map, sub_key, value) end)
  end
end
