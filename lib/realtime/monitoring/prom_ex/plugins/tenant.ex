defmodule Realtime.PromEx.Plugins.Tenant do
  @moduledoc false

  use PromEx.Plugin
  require Logger
  alias Realtime.Telemetry
  alias Realtime.Tenants
  alias Realtime.UsersCounter

  @impl true
  def polling_metrics(opts) do
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)

    [
      concurrent_connections(poll_rate)
    ]
  end

  @impl true
  def event_metrics(_opts) do
    # Event metrics definitions
    [
      channel_events(),
      replication_metrics()
    ]
  end

  defp concurrent_connections(poll_rate) do
    Polling.build(
      :realtime_concurrent_connections,
      poll_rate,
      {__MODULE__, :execute_tenant_metrics, []},
      [
        last_value(
          [:realtime, :connections, :connected],
          event_name: [:realtime, :connections],
          description: "The node total count of connected clients for a tenant.",
          measurement: :connected,
          tags: [:tenant]
        ),
        last_value(
          [:realtime, :connections, :connected_cluster],
          event_name: [:realtime, :connections],
          description: "The cluster total count of connected clients for a tenant.",
          measurement: :connected_cluster,
          tags: [:tenant]
        ),
        last_value(
          [:realtime, :connections, :limit_concurrent],
          event_name: [:realtime, :connections],
          description: "The total count of connected clients for a tenant.",
          measurement: :limit,
          tags: [:tenant]
        )
      ]
    )
  end

  def execute_tenant_metrics() do
    tenants = Tenants.list_connected_tenants(Node.self())

    for t <- tenants do
      count = UsersCounter.tenant_users(Node.self(), t)
      cluster_count = UsersCounter.tenant_users(t)
      tenant = Tenants.Cache.get_tenant_by_external_id(t)

      Telemetry.execute(
        [:realtime, :connections],
        %{connected: count, connected_cluster: cluster_count, limit: tenant.max_concurrent_users},
        %{tenant: t}
      )
    end
  end

  defp replication_metrics() do
    Event.build(
      :realtime_tenant_replication_event_metrics,
      [
        distribution(
          [:realtime, :replication, :poller, :query, :duration],
          event_name: [:realtime, :replication, :poller, :query, :stop],
          measurement: :duration,
          description: "Duration of the logical replication slot polling query for Realtime RLS.",
          tags: [:tenant],
          unit: {:microsecond, :millisecond},
          reporter_options: [
            buckets: [125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 64_000]
          ]
        )
      ]
    )
  end

  defp channel_events() do
    Event.build(
      :realtime_tenant_channel_event_metrics,
      [
        sum(
          [:realtime, :channel, :events],
          event_name: [:realtime, :rate_counter, :channel, :events],
          measurement: :sum,
          description: "Sum of messages sent on a Realtime Channel.",
          tags: [:tenant]
        ),
        last_value(
          [:realtime, :channel, :events, :limit_per_second],
          event_name: [:realtime, :rate_counter, :channel, :events],
          measurement: :limit,
          description: "Rate limit of messages per second sent on a Realtime Channel.",
          tags: [:tenant]
        ),
        sum(
          [:realtime, :channel, :joins],
          event_name: [:realtime, :rate_counter, :channel, :joins],
          measurement: :sum,
          description: "Sum of Realtime Channel joins.",
          tags: [:tenant]
        ),
        last_value(
          [:realtime, :channel, :joins, :limit_per_second],
          event_name: [:realtime, :rate_counter, :channel, :joins],
          measurement: :limit,
          description: "Rate limit of joins per second on a Realtime Channel.",
          tags: [:tenant]
        )
      ]
    )
  end
end
