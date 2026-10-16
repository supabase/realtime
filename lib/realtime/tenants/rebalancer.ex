defmodule Realtime.Tenants.Rebalancer do
  @moduledoc """
  Responsible to tell if the executing node is in the correct region for this tenant
  """

  alias Realtime.Api.Tenant
  alias Realtime.Nodes

  @spec check(MapSet.t(node), MapSet.t(node), binary) :: :ok | {:error, :wrong_region}
  def check(previous_nodes_set, current_nodes_set, tenant_id)
      when is_struct(previous_nodes_set, MapSet) and is_struct(current_nodes_set, MapSet) and is_binary(tenant_id) do
    # Check if the current nodes set is equal to the previous nodes set
    # If they are equal it means that the cluster is relatively stable
    # We can check now if this Connect process is in the correct region
    if MapSet.equal?(current_nodes_set, previous_nodes_set) do
      with %Tenant{} = tenant <- Realtime.Tenants.Cache.get_tenant_by_external_id(tenant_id),
           {:ok, _node, expected_region} <- Nodes.get_node_for_tenant(tenant) do
        # Either we are already in the right region, or there are no nodes in the expected region
        # for us to rebalance to
        if Nodes.region() == expected_region or expected_region |> Nodes.region_nodes() |> Enum.empty?() do
          :ok
        else
          {:error, :wrong_region}
        end
      else
        _ -> :ok
      end
    else
      # Nodes have changed, we can assume that the cluster is not stable enough to rebalance
      :ok
    end
  end
end
