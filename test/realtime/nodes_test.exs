defmodule Realtime.NodesTest do
  use Realtime.DataCase, async: true
  use Mimic
  alias Realtime.Nodes
  alias Realtime.Tenants

  defp spawn_fake_node(region, node) do
    parent = self()

    fun = fn ->
      :syn.join(RegionNodes, region, self(), node: node)
      send(parent, :joined)

      receive do
        :ok -> :ok
      end
    end

    {:ok, _pid} = start_supervised({Task, fun}, id: {region, node})
    assert_receive :joined
  end

  describe "region_nodes/1" do
    test "nil region returns empty list" do
      assert Nodes.region_nodes(nil) == []
    end

    test "returns nodes from region" do
      region = "ap-southeast-2"
      spawn_fake_node(region, :node_1)
      spawn_fake_node(region, :node_2)

      spawn_fake_node("eu-west-2", :node_3)

      assert Nodes.region_nodes(region) == [:node_1, :node_2]
      assert Nodes.region_nodes("eu-west-2") == [:node_3]
    end

    test "on non-existing region, returns empty list" do
      assert Nodes.region_nodes("non-existing-region") == []
    end
  end

  describe "node_from_region/2" do
    test "nil region returns error" do
      assert {:error, :not_available} = Nodes.node_from_region(nil, :any_key)
    end

    test "empty region returns error" do
      assert {:error, :not_available} = Nodes.node_from_region("empty-region", :any_key)
    end

    test "returns the same node given the same key" do
      region = "ap-southeast-3"
      spawn_fake_node(region, :node_1)
      spawn_fake_node(region, :node_2)

      spawn_fake_node("eu-west-3", :node_3)

      assert {:ok, :node_2} = Nodes.node_from_region(region, :key1)
      assert {:ok, :node_2} = Nodes.node_from_region(region, :key1)
    end
  end

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

    test "on existing tenant id, returns the node for the region using syn", %{tenant: tenant, region: region} do
      expected_nodes = [:tenant@closest1, :tenant@closest2]

      expect(:syn, :members, fn RegionNodes, ^region ->
        [
          {self(), [node: Enum.at(expected_nodes, 0)]},
          {self(), [node: Enum.at(expected_nodes, 1)]}
        ]
      end)

      index = :erlang.phash2(tenant.external_id, length(expected_nodes))

      expected_node = Enum.fetch!(expected_nodes, index)
      expected_region = Tenants.region(tenant)

      assert {:ok, node, region} = Nodes.get_node_for_tenant(tenant)
      assert node == expected_node
      assert region == expected_region
    end

    test "on existing tenant id, and a single node for a given region, returns default", %{
      tenant: tenant,
      region: region
    } do
      expect(:syn, :members, fn RegionNodes, ^region -> [{self(), [node: :tenant@closest1]}] end)
      assert {:ok, node, region} = Nodes.get_node_for_tenant(tenant)

      expected_region = Tenants.region(tenant)

      assert node == node()
      assert region == expected_region
    end

    test "on existing tenant id, returns default node for regions not registered in syn", %{tenant: tenant} do
      expect(:syn, :members, fn RegionNodes, _ -> [] end)
      assert {:ok, node, region} = Nodes.get_node_for_tenant(tenant)

      expected_region = Tenants.region(tenant)

      assert node == node()
      assert region == expected_region
    end
  end
end
