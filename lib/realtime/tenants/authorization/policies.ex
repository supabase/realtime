defmodule Realtime.Tenants.Authorization.Policies do
  @moduledoc """
  Policies structure that holds the required authorization information for a given connection.

  Also defines a behaviour to be used by the different authorization modules to build and check policies within the context of an entity.

  Currently there are two types of policies:
  * Realtime.Tenants.Authorization.Policies.TopicPolicies - Used to check access to the Channel itself
  * Realtime.Tenants.Authorization.Policies.BroadcastPolicies - Used to check access to the Broadcast feature on a given Channel
  * Realtime.Tenants.Authorization.Policies.PresencePolicies - Used to check access to Presence feature on a given Channel
  """

  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.TopicPolicies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies

  defstruct topic: %TopicPolicies{},
            broadcast: %BroadcastPolicies{},
            presence: %PresencePolicies{}

  @type t :: %__MODULE__{
          topic: TopicPolicies.t(),
          broadcast: BroadcastPolicies.t(),
          presence: PresencePolicies.t()
        }

  @doc """
  Implementation of the method on how to check read policies for a given entity within the context of a database connection

  Arguments:
    * `db_conn` - The database connection with the required context to properly run checks
    * `policies` - The policies struct to which the result will be accumulated
    * `authorization` - The authorization struct with required information for Policy checking
  """
  @callback check_read_policies(DBConnection.t(), t(), Authorization.t()) ::
              {:ok, t()} | {:error, any()}
  @doc """
  Implementation of the method on how to check write policies for a given entity within the context of a database connection

  Arguments:
    * `db_conn` - The database connection with the required context to properly run checks
    * `policies` - The policies struct to which the result will be accumulated
    * `authorization` - The authorization struct with required information for policy checking
  """
  @callback check_write_policies(DBConnection.t(), t(), Authorization.t()) ::
              {:ok, t()} | {:error, any()}

  @doc """
  Updates the Policies struct sub key with the given value.
  """
  @spec update_policies(t(), atom, atom, boolean) :: t()
  def update_policies(policies, key, sub_key, value) do
    Map.update!(policies, key, fn map -> Map.put(map, sub_key, value) end)
  end
end
