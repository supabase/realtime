defmodule Realtime.Tenants.Rebalancer do
  @moduledoc """
  Responsible to tell if the executing node is in the correct region for this tenant

  `check/3` returns one of these values:

  * `:ok` - this node is in the expected region of the tenant.
  * `:retry` - no decision for now, the caller checks again later.
  * `{:error, :wrong_region}` - this node is not in the expected region, and that region has nodes to rebalance to.
  """

  alias Realtime.Api.Tenant
  alias Realtime.Nodes

  @spec check(MapSet.t(node), MapSet.t(node), binary) :: :ok | :retry | {:error, :wrong_region}
  def check(previous_nodes_set, current_nodes_set, tenant_id)
      when is_struct(previous_nodes_set, MapSet) and is_struct(current_nodes_set, MapSet) and is_binary(tenant_id) do
    # Check if the current nodes set is equal to the previous nodes set
    # If they are equal it means that the cluster is relatively stable
    # We can check now if this Connect process is in the correct region
    if MapSet.equal?(current_nodes_set, previous_nodes_set) do
      with %Tenant{} = tenant <- Realtime.Tenants.Cache.get_tenant_by_external_id(tenant_id) do
        expected_region = Nodes.launch_region(tenant)

        cond do
          Nodes.region() == expected_region -> :ok
          # There are no nodes in the expected region for us to rebalance to
          expected_region |> Nodes.region_nodes() |> Enum.empty?() -> :retry
          true -> {:error, :wrong_region}
        end
      else
        _ -> :retry
      end
    else
      # Nodes have changed, we can assume that the cluster is not stable enough to rebalance
      :retry
    end
  end
end
