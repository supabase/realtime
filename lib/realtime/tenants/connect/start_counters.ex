defmodule Realtime.Tenants.Connect.StartCounters do
  @moduledoc """
  Start tenant counters.
  """

  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.Cache

  @behaviour Realtime.Tenants.Connect.Piper

  @impl true
  def run(acc) do
    %{tenant_id: tenant_id} = acc
    tenant = Cache.get_tenant_by_external_id(tenant_id)

    with {:ok, _} <- start_joins_per_second_counter(tenant),
         {:ok, _} <- start_max_events_counter(tenant),
         {:ok, _} <- start_db_events_counter(tenant) do
    end

    {:ok, acc}
  end

  def start_joins_per_second_counter(tenant) do
    %{max_joins_per_second: max_joins_per_second} = tenant
    id = Tenants.joins_per_second_key(tenant)
    GenCounter.new(id)

    RateCounter.new(id,
      idle_shutdown: :infinity,
      telemetry: %{
        event_name: [:channel, :joins],
        measurements: %{limit: max_joins_per_second},
        metadata: %{tenant: tenant}
      }
    )
  end

  def start_max_events_counter(tenant) do
    %{max_events_per_second: max_events_per_second} = tenant

    key = Tenants.events_per_second_key(tenant)

    GenCounter.new(key)

    RateCounter.new(key,
      idle_shutdown: :infinity,
      telemetry: %{
        event_name: [:channel, :events],
        measurements: %{limit: max_events_per_second},
        metadata: %{tenant: tenant}
      }
    )
  end

  def start_db_events_counter(tenant) do
    key = Tenants.db_events_per_second_key(tenant)
    GenCounter.new(key)

    RateCounter.new(key,
      idle_shutdown: :infinity,
      telemetry: %{
        event_name: [:channel, :db_events],
        measurements: %{},
        metadata: %{tenant: tenant}
      }
    )
  end
end
