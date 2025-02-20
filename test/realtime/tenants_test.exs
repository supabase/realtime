defmodule Realtime.TenantsTest do
  # async: false due to cache usage
  use Realtime.DataCase, async: false

  alias Realtime.GenCounter
  alias Realtime.Tenants
  doctest Realtime.Tenants

  describe "tenants" do
    test "get_tenant_limits/1" do
      tenant = tenant_fixture()
      start_supervised(GenCounter)
      keys = Tenants.limiter_keys(tenant)

      for key <- keys do
        GenCounter.new(key)
        GenCounter.add(key, 9)
      end

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

  describe "suspend_tenant_by_external_id/1" do
    test "sets suspend flag to true and publishes message" do
      topic = "realtime:operations:invalidate_cache"
      Phoenix.PubSub.subscribe(Realtime.PubSub, topic)
      %{external_id: external_id} = tenant_fixture(%{suspend: false})

      Tenants.suspend_tenant_by_external_id(external_id)

      %{suspend: suspend, external_id: external_id} = Tenants.Cache.get_tenant_by_external_id(external_id)
      assert suspend == true
      assert_receive {:suspend_tenant, ^external_id}
    end
  end

  describe "unsuspend_tenant_by_external_id/1" do
    test "sets suspend flag to false and publishes message" do
      topic = "realtime:operations:invalidate_cache"
      Phoenix.PubSub.subscribe(Realtime.PubSub, topic)
      %{external_id: external_id} = tenant_fixture(%{suspend: true})

      Tenants.unsuspend_tenant_by_external_id(external_id)

      %{suspend: suspend, external_id: external_id} = Tenants.Cache.get_tenant_by_external_id(external_id)
      assert suspend == false
      assert_receive {:unsuspend_tenant, ^external_id}
    end
  end
end
