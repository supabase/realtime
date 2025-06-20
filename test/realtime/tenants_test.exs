defmodule Realtime.TenantsTest do
  # async: false due to cache usage
  alias Realtime.Tenants.Migrations
  use Realtime.DataCase, async: false

  alias Realtime.GenCounter
  alias Realtime.Tenants
  doctest Realtime.Tenants

  describe "tenants" do
    test "get_tenant_limits/1" do
      tenant = tenant_fixture()
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
    setup do
      tenant = tenant_fixture()
      topic = "realtime:operations:" <> tenant.external_id
      Phoenix.PubSub.subscribe(Realtime.PubSub, topic)
      %{topic: topic, tenant: tenant}
    end

    test "sets suspend flag to true and publishes message", %{tenant: %{external_id: external_id}} do
      tenant = Tenants.suspend_tenant_by_external_id(external_id)
      assert tenant.suspend == true
      assert_receive :suspend_tenant, 500
    end

    test "does not publish message if if not targetted tenant", %{tenant: tenant} do
      Tenants.suspend_tenant_by_external_id(tenant_fixture().external_id)
      tenant = Repo.reload!(tenant)
      assert tenant.suspend == false
      refute_receive :suspend_tenant, 500
    end
  end

  describe "unsuspend_tenant_by_external_id/1" do
    setup do
      tenant = tenant_fixture(%{suspend: true})
      topic = "realtime:operations:" <> tenant.external_id
      Phoenix.PubSub.subscribe(Realtime.PubSub, topic)
      %{topic: topic, tenant: tenant}
    end

    test "sets suspend flag to false and publishes message", %{tenant: tenant} do
      tenant = Tenants.unsuspend_tenant_by_external_id(tenant.external_id)
      assert tenant.suspend == false
      assert_receive :unsuspend_tenant, 500
    end

    test "does not publish message if not targetted tenant", %{tenant: tenant} do
      Tenants.unsuspend_tenant_by_external_id(tenant_fixture().external_id)
      tenant = Repo.reload!(tenant)
      assert tenant.suspend == true
      refute_receive :unsuspend_tenant, 500
    end
  end

  describe "run_migrations?/1" do
    test "returns true if migrations_ran is lower than existing migrations" do
      tenant = tenant_fixture(%{migrations_ran: 0})
      assert Tenants.run_migrations?(tenant)

      tenant = tenant_fixture(%{migrations_ran: Enum.count(Migrations.migrations()) - 1})
      assert Tenants.run_migrations?(tenant)
    end

    test "returns false if migrations_ran is count of all migrations" do
      tenant = tenant_fixture(%{migrations_ran: Enum.count(Migrations.migrations())})
      refute Tenants.run_migrations?(tenant)
    end
  end

  describe "update_migrations_ran/1" do
    test "updates migrations_ran to the count of all migrations" do
      tenant = tenant_fixture(%{migrations_ran: 0})
      Tenants.update_migrations_ran(tenant.external_id, 1)
      tenant = Repo.reload!(tenant)
      assert tenant.migrations_ran == 1
    end
  end

  describe "broadcast_operation_event/2" do
    setup do
      tenant = tenant_fixture()
      topic = "realtime:operations:" <> tenant.external_id
      Phoenix.PubSub.subscribe(Realtime.PubSub, topic)
      %{tenant: tenant}
    end

    test "broadcasts events to the targetted tenant", %{tenant: tenant} do
      events = [
        :suspend_tenant,
        :unsuspend_tenant,
        :disconnect
      ]

      for event <- events do
        Tenants.broadcast_operation_event(event, tenant.external_id)
        assert_receive ^event
      end
    end
  end
end
