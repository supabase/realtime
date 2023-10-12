defmodule Realtime.NodesTest do
  use Realtime.DataCase
  alias Realtime.Nodes
  import Mock

  describe "get_node_for_tenant/1" do
    setup do
      tenant = tenant_fixture()
      region = tenant.extensions |> hd() |> Map.get(:settings) |> Map.get("region")

      %{tenant: tenant, region: region}
    end

    test "nil call returns error" do
      with_mock :syn, members: fn _, _ -> nil end do
        assert {:error, :tenant_not_found} = Nodes.get_node_for_tenant(nil)
        assert_not_called(:syn.member(:_))
      end
    end

    test "on existing tenant id, returns the node for the region using syn", %{
      tenant: tenant,
      region: region
    } do
      expected_nodes = [:tenant@closest1, :tenant@closest2]

      with_mock :syn,
        members: fn RegionNodes, ^region ->
          [
            {self(), [node: Enum.at(expected_nodes, 0)]},
            {self(), [node: Enum.at(expected_nodes, 1)]}
          ]
        end do
        index = :erlang.phash2(tenant.external_id, length(expected_nodes))
        expected_node = Enum.fetch!(expected_nodes, index)

        assert {:ok, node} = Nodes.get_node_for_tenant(tenant)
        assert node == expected_node
      end
    end

    test "on existing tenant id, and a single node for a given region, returns default", %{
      tenant: tenant,
      region: region
    } do
      with_mock :syn,
        members: fn RegionNodes, ^region ->
          [
            {self(), [node: :tenant@closest1]}
          ]
        end do
        assert {:ok, node} = Nodes.get_node_for_tenant(tenant)
        assert node == node()
      end
    end

    test "on existing tenant id, returns default node for regions not registered in syn", %{
      tenant: tenant
    } do
      with_mock :syn,
        members: fn RegionNodes, _ -> [] end do
        assert {:ok, node} = Nodes.get_node_for_tenant(tenant)
        assert node == node()
      end
    end
  end
end
