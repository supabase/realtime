defmodule Realtime.TenantsTest do
  use Realtime.DataCase

  import Mock

  alias Realtime.GenCounter
  alias Realtime.Tenants
  doctest Realtime.Tenants

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
    setup do
      tenant = tenant_fixture()
      topic = "realtime:operations:invalidate_cache"
      Phoenix.PubSub.subscribe(Realtime.PubSub, topic)
      %{topic: topic, tenant: tenant}
    end

    test "sets suspend flag to true and publishes message", %{tenant: %{external_id: external_id}} do
      tenant = Tenants.suspend_tenant_by_external_id(external_id)
      assert tenant.suspend == true
      assert_receive {:suspend_tenant, ^external_id}, 1000
    end
  end

  describe "unsuspend_tenant_by_external_id/1" do
    setup do
      tenant = tenant_fixture()
      topic = "realtime:operations:invalidate_cache"
      Phoenix.PubSub.subscribe(Realtime.PubSub, topic)
      %{topic: topic, tenant: tenant}
    end

    test "sets suspend flag to false and publishes message" do
      %{external_id: external_id} = tenant_fixture(suspend: true)
      tenant = Tenants.unsuspend_tenant_by_external_id(external_id)
      assert tenant.suspend == false
      assert_receive {:unsuspend_tenant, ^external_id}, 1000
    end
  end
end
