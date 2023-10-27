defmodule Realtime.TenantsTest do
  use Realtime.DataCase

  import Mock

  alias Realtime.GenCounter
  alias Realtime.Tenants
  alias Realtime.Api.Tenant

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
      topic = "tenant:operations:#{tenant.external_id}"
      Phoenix.PubSub.subscribe(Realtime.PubSub, topic)
      %{topic: topic, tenant: tenant}
    end

    test "sets suspend flag to true and publishes message", %{tenant: tenant} do
      tenant = Tenants.suspend_tenant_by_external_id(tenant.external_id)
      assert tenant.suspend == true
      assert_receive :suspend
    end

    test "invalidates tenants cache", %{tenant: tenant} do
      assert %Tenant{suspend: false} =
               Realtime.Tenants.Cache.get_tenant_by_external_id(tenant.external_id)

      Tenants.suspend_tenant_by_external_id(tenant.external_id)

      assert %{suspend: true} =
               Realtime.Tenants.Cache.get_tenant_by_external_id(tenant.external_id)
    end
  end

  describe "unsuspend_tenant_by_external_id/1" do
    setup do
      tenant = tenant_fixture()
      topic = "tenant:operations:#{tenant.external_id}"
      Phoenix.PubSub.subscribe(Realtime.PubSub, topic)
      %{topic: topic, tenant: tenant}
    end

    test "sets suspend flag to true and publishes message", %{tenant: tenant} do
      Tenants.suspend_tenant_by_external_id(tenant.external_id)
      tenant = Tenants.unsuspend_tenant_by_external_id(tenant.external_id)

      assert tenant.suspend == false
      assert_receive :unsuspend
    end

    test "invalidates tenants cache" do
      tenant = tenant_fixture(suspend: true)

      assert %Tenant{suspend: true} =
               Realtime.Tenants.Cache.get_tenant_by_external_id(tenant.external_id)

      Tenants.unsuspend_tenant_by_external_id(tenant.external_id)

      assert %{suspend: false} =
               Realtime.Tenants.Cache.get_tenant_by_external_id(tenant.external_id)
    end
  end
end
