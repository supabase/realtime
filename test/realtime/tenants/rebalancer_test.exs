defmodule Realtime.Tenants.RebalancerTest do
  use Realtime.DataCase, async: true

  alias Realtime.Tenants.Rebalancer
  alias Realtime.Nodes

  use Mimic

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    # Warm cache to avoid Cachex and Ecto.Sandbox ownership issues
    Cachex.put!(Realtime.Tenants.Cache, {{:get_tenant_by_external_id, 1}, [tenant.external_id]}, {:cached, tenant})
    %{tenant: tenant}
  end

  describe "check/3" do
    test "different node set returns :ok", %{tenant: tenant} do
      external_id = tenant.external_id

      # Don't even try to look for the region
      reject(&Nodes.get_node_for_tenant/1)

      assert Rebalancer.check(MapSet.new([node()]), MapSet.new([node(), :other_node]), external_id) == :ok
    end

    test "same node set correct region set returns :ok", %{tenant: tenant} do
      external_id = tenant.external_id
      current_region = Application.fetch_env!(:realtime, :region)

      expect(Nodes, :get_node_for_tenant, fn ^tenant -> {:ok, :some_node, current_region} end)
      reject(&Nodes.get_node_for_tenant/1)

      assert Rebalancer.check(MapSet.new([node(), :some_node]), MapSet.new([node(), :some_node]), external_id) == :ok
    end

    test "same node set different region set returns :ok", %{tenant: tenant} do
      external_id = tenant.external_id
      current_region = Application.fetch_env!(:realtime, :region)

      expect(Nodes, :get_node_for_tenant, fn ^tenant -> {:ok, :some_node, "ap-southeast-1"} end)
      reject(&Nodes.get_node_for_tenant/1)

      assert Rebalancer.check(MapSet.new([node(), :some_node]), MapSet.new([node(), :some_node]), external_id) ==
               {:error, :wrong_region}
    end
  end
end
