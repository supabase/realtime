defmodule Realtime.TenantQuotaUpdateTest do
  use Realtime.DataCase, async: false
  use Mimic

  alias Realtime.Api
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.Cache

  setup :set_mimic_global

  test "applies the tenant quota before restarting its local rate counter" do
    tenant = tenant_fixture(%{max_events_per_second: 1})
    Cache.update_cache(tenant)
    rate = Tenants.events_per_second_rate(tenant)
    counter = RateCounterHelper.new!(rate)
    monitor = Process.monitor(counter)
    parent = self()

    stub(Cachex, :put, fn cache, key, value ->
      if cache == Cache and
           match?(%{external_id: id, max_events_per_second: 1000} when id == tenant.external_id, value) do
        send(parent, {:cache_write_waiting, self()})

        receive do
          :resume -> :ok
        after
          5_000 -> raise "tenant cache write was not released"
        end
      end

      Mimic.call_original(Cachex, :put, [cache, key, value])
    end)

    assert {:ok, %{max_events_per_second: 1000}} =
             Api.update_tenant_by_external_id(tenant.external_id, %{max_events_per_second: 1000})

    assert_receive {:cache_write_waiting, writer}, 2_000

    on_exit(fn ->
      send(writer, :resume)
      RateCounterHelper.stop(tenant.external_id)
    end)

    assert %{max_events_per_second: 1} = Cache.get_tenant_by_external_id(tenant.external_id)
    refute_receive {:DOWN, ^monitor, :process, ^counter, _}, 100

    send(writer, :resume)
    assert_receive {:DOWN, ^monitor, :process, ^counter, :normal}, 2_000
    assert %{max_events_per_second: 1000} = Cache.get_tenant_by_external_id(tenant.external_id)
    assert_eventually(Cachex.get(RateCounter, rate.id) == {:ok, nil}, timeout: 2_000)

    socket = %Phoenix.Socket{assigns: %{tenant: tenant.external_id}}
    assert {:noreply, ^socket} = RealtimeWeb.RealtimeChannel.handle_info(:check_rate_counter, socket)
    assert {:ok, %{limit: %{value: 1000}}} = RateCounter.get(rate)

    GenCounter.add(rate.id, 100)
    assert {:ok, %{limit: %{value: 1000, triggered: false}, avg: avg}} = RateCounterHelper.tick!(rate)
    assert avg > 1 and avg < 1000
  end
end
