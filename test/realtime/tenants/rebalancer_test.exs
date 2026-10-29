defmodule Realtime.Tenants.RebalancerTest do
  use Realtime.DataCase, async: true

  alias Realtime.Tenants.Rebalancer
  alias Realtime.Nodes

  use Mimic

  import ExUnit.CaptureLog

  setup :set_mimic_from_context

  setup do
    %{tenant: TestTenantDb.checkout_tenant(run_migrations: true)}
  end

  describe "check/3" do
    test "different node set returns :ok", %{tenant: tenant} do
      external_id = tenant.external_id

      # Don't even try to look for the region
      reject(&Nodes.launch_region/1)

      assert Rebalancer.check(MapSet.new([node()]), MapSet.new([node(), :other_node]), external_id) == :ok
    end

    test "same node set correct region set returns :ok", %{tenant: tenant} do
      external_id = tenant.external_id
      current_region = Nodes.region()

      expect(Nodes, :launch_region, fn ^tenant -> current_region end)
      reject(&Nodes.launch_region/1)

      assert Rebalancer.check(MapSet.new([node(), :some_node]), MapSet.new([node(), :some_node]), external_id) == :ok
    end

    test "same node set different region set returns :ok", %{tenant: tenant} do
      external_id = tenant.external_id

      expect(Nodes, :launch_region, fn ^tenant -> "ap-southeast-1" end)
      reject(&Nodes.launch_region/1)
      expect(Nodes, :region_nodes, fn "ap-southeast-1" -> [:some_node] end)

      assert Rebalancer.check(MapSet.new([node(), :some_node]), MapSet.new([node(), :some_node]), external_id) ==
               {:error, :wrong_region}
    end

    test "same node set different region set without nodes in that region returns :ok", %{tenant: tenant} do
      external_id = tenant.external_id
      [%{settings: settings} = extension] = tenant.extensions

      # No node in this cluster belongs to us-west-2, like a single-node self-hosted Realtime left on the
      # default "local" region serving its seeded us-east-1 tenant
      tenant = %{tenant | extensions: [%{extension | settings: Map.put(settings, "region", "us-west-2")}]}
      Realtime.Tenants.Cache.update_cache(tenant)

      assert Nodes.launch_region(tenant) == "us-west-2"
      assert Nodes.region_nodes("us-west-2") == []

      # Tag this test's log lines, async tests may log the same warning concurrently
      Logger.metadata(external_id: external_id)

      log =
        capture_log([format: "$metadata$message\n", metadata: [:external_id]], fn ->
          assert Rebalancer.check(MapSet.new([node()]), MapSet.new([node()]), external_id) == :ok
        end)

      # The check only needs the region, picking a node would warn on every check
      refute log =~ "external_id=#{external_id} Zero region nodes for"
    end
  end
end
