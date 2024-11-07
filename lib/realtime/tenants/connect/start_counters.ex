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

    with tenant when not is_nil(tenant) <- Cache.get_tenant_by_external_id(tenant_id),
         :ok <- start_joins_per_second_counter(tenant),
         :ok <- start_max_events_counter(tenant),
         :ok <- start_db_events_counter(tenant) do
      {:ok, acc}
    else
      nil -> {:error, "Tenant not found"}
      {:error, reason} -> {:error, reason}
    end
  end

  def start_joins_per_second_counter(tenant) do
    %{max_joins_per_second: max_joins_per_second} = tenant
    id = Tenants.joins_per_second_key(tenant)
    GenCounter.new(id)

    res =
      RateCounter.new(id,
        idle_shutdown: :infinity,
        telemetry: %{
          event_name: [:channel, :joins],
          measurements: %{limit: max_joins_per_second},
          metadata: %{tenant: tenant.external_id}
        }
      )

    case res do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def start_max_events_counter(tenant) do
    %{max_events_per_second: max_events_per_second} = tenant

    key = Tenants.events_per_second_key(tenant)

    GenCounter.new(key)

    res =
      RateCounter.new(key,
        idle_shutdown: :infinity,
        telemetry: %{
          event_name: [:channel, :events],
          measurements: %{limit: max_events_per_second},
          metadata: %{tenant: tenant.external_id}
        }
      )

    case res do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def start_db_events_counter(tenant) do
    key = Tenants.db_events_per_second_key(tenant)
    GenCounter.new(key)

    res =
      RateCounter.new(key,
        idle_shutdown: :infinity,
        telemetry: %{
          event_name: [:channel, :db_events],
          measurements: %{},
          metadata: %{tenant: tenant.external_id}
        }
      )

    case res do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
