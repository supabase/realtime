defmodule Realtime.Tenants.Authorization.Policies do
  @moduledoc """
  Policies structure that holds the required authorization information for a given connection.

  * Realtime.Tenants.Authorization.Policies.BroadcastPolicies - Broadcast feature access
  * Realtime.Tenants.Authorization.Policies.PresencePolicies - Presence feature access
  * Realtime.Tenants.Authorization.Policies.AiPolicies - AI agent feature access
  """

  alias Realtime.Tenants.Authorization.Policies.AiPolicies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies

  defstruct broadcast: %BroadcastPolicies{},
            presence: %PresencePolicies{},
            ai_agent: %AiPolicies{}

  @type t :: %__MODULE__{
          broadcast: BroadcastPolicies.t(),
          presence: PresencePolicies.t(),
          ai_agent: AiPolicies.t()
        }

  @doc """
  Updates the Policies struct sub key with the given value.
  """
  @spec update_policies(t(), atom, atom, boolean) :: t()
  def update_policies(policies, key, sub_key, value) do
    Map.update!(policies, key, fn map -> Map.put(map, sub_key, value) end)
  end
end
