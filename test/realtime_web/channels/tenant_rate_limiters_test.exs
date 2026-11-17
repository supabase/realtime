defmodule RealtimeWeb.TenantRateLimitersTest do
  use Realtime.DataCase, async: true

  use Mimic

  setup :set_mimic_from_context

  alias RealtimeWeb.TenantRateLimiters
  alias Realtime.Api.Tenant

  setup do
    tenant = %Tenant{external_id: random_string(), max_concurrent_users: 1, max_joins_per_second: 1}

    %{tenant: tenant}
  end

  describe "check_tenant/1" do
    test "rate is not exceeded", %{tenant: tenant} do
      assert TenantRateLimiters.check_tenant(tenant) == :ok
    end

    test "max concurrent users is exceeded", %{tenant: tenant} do
      Realtime.UsersCounter.add(self(), tenant.external_id)

      assert TenantRateLimiters.check_tenant(tenant) == {:error, :too_many_connections}
    end

    test "max joins is exceeded", %{tenant: tenant} do
      expect(Realtime.RateCounter, :get, fn _ -> {:ok, %{limit: %{triggered: true}}} end)

      assert TenantRateLimiters.check_tenant(tenant) == {:error, :too_many_joins}
    end

    test "node join budget is used up while the node_join_budget flag is on", %{tenant: tenant} do
      stub(Realtime.FeatureFlags, :enabled?, fn name, _tenant_id -> name == "node_join_budget" end)
      use_up_node_join_budget(tenant)

      assert TenantRateLimiters.check_tenant(tenant) == {:error, :too_many_node_joins}
    end

    test "node join budget is not used up while the node_join_budget flag is on", %{tenant: tenant} do
      stub(Realtime.FeatureFlags, :enabled?, fn name, _tenant_id -> name == "node_join_budget" end)

      assert TenantRateLimiters.check_tenant(tenant) == :ok
    end

    test "node join budget is used up while the node_join_budget flag is off", %{tenant: tenant} do
      stub(Realtime.FeatureFlags, :enabled?, fn _name, _tenant_id -> false end)
      use_up_node_join_budget(tenant)

      assert TenantRateLimiters.check_tenant(tenant) == :ok
    end
  end

  # Takes every join a minute ahead, so the bucket stays empty for the rest of the test
  defp use_up_node_join_budget(tenant) do
    future = System.monotonic_time(:microsecond) + 60_000_000
    Stream.repeatedly(fn -> Realtime.Tenants.NodeJoinBudget.take(tenant, future) end) |> Enum.find(&(&1 == :error))
  end
end
