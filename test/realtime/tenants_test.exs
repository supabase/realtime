defmodule Realtime.TenantsTest do
  use Realtime.DataCase

  import Mock

  alias Realtime.GenCounter
  alias Realtime.Tenants

  describe "tenants" do
    test "get_tenant_limits/1" do
      tenant = tenant_fixture()

      with_mocks([
        {GenCounter, [], [get: fn _ -> {:ok, 9} end]}
      ]) do
        keys = Tenants.limiter_keys(tenant)
        limits = Tenants.get_tenant_limits(tenant, keys)

        [all] =
          Enum.filter(limits, fn e -> e.limiter == Tenants.requests_per_second_key(tenant) end)

        assert all.counter == 9

        [user_channels] =
          Enum.filter(limits, fn e -> e.limiter == Tenants.channels_per_client_key(tenant) end)

        assert user_channels.counter == 9

        [channel_joins] =
          Enum.filter(limits, fn e -> e.limiter == Tenants.joins_per_second_key(tenant) end)

        assert channel_joins.counter == 9

        [tenant_events] =
          Enum.filter(limits, fn e -> e.limiter == Tenants.events_per_second_key(tenant) end)

        assert tenant_events.counter == 9
      end
    end
  end

  describe "suspend_tenant_by_external_id/1" do
    test "sets suspend flag to true" do
      tenant = tenant_fixture()
      {:ok, tenant} = Tenants.suspend_tenant_by_external_id(tenant.external_id)

      assert tenant.suspend == true
    end
  end

  describe "unsuspend_tenant_by_external_id/1" do
    test "sets suspend flag to true" do
      tenant = tenant_fixture(suspend: true)
      {:ok, tenant} = Tenants.unsuspend_tenant_by_external_id(tenant.external_id)

      assert tenant.suspend == false
    end
  end
end
