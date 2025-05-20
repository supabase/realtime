defmodule Realtime.NodesTest do
  use Realtime.DataCase, async: true
  use Mimic
  alias Realtime.Nodes

  describe "get_node_for_tenant/1" do
    setup do
      tenant = Containers.checkout_tenant()
      region = tenant.extensions |> hd() |> get_in([Access.key!(:settings), "region"])
      %{tenant: tenant, region: region}
    end

    test "nil call returns error" do
      assert {:error, :tenant_not_found} = Nodes.get_node_for_tenant(nil)
      reject(&:syn.members/2)
    end

    test "on existing tenant id, returns the node for the region using syn", %{
      tenant: tenant,
      region: region
    } do
      expected_nodes = [:tenant@closest1, :tenant@closest2]

      expect(:syn, :members, fn RegionNodes, ^region ->
        [
          {self(), [node: Enum.at(expected_nodes, 0)]},
          {self(), [node: Enum.at(expected_nodes, 1)]}
        ]
      end)

      index = :erlang.phash2(tenant.external_id, length(expected_nodes))
      expected_node = Enum.fetch!(expected_nodes, index)

      assert {:ok, node} = Nodes.get_node_for_tenant(tenant)
      assert node == expected_node
    end

    test "on existing tenant id, and a single node for a given region, returns default", %{
      tenant: tenant,
      region: region
    } do
      expect(:syn, :members, fn RegionNodes, ^region -> [{self(), [node: :tenant@closest1]}] end)
      assert {:ok, node} = Nodes.get_node_for_tenant(tenant)
      assert node == node()
    end

    test "on existing tenant id, returns default node for regions not registered in syn", %{tenant: tenant} do
      expect(:syn, :members, fn RegionNodes, _ -> [] end)
      assert {:ok, node} = Nodes.get_node_for_tenant(tenant)
      assert node == node()
    end
  end
end
