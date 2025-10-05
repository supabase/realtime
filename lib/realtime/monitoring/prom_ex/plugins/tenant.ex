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
      replication_metrics(),
      subscription_metrics(),
      payload_size_metrics()
    ]
  end

  defp payload_size_metrics do
    Event.build(
      :realtime_tenant_payload_size_metrics,
      [
        distribution(
          [:realtime, :tenants, :payload, :size],
          event_name: [:realtime, :tenants, :payload, :size],
          measurement: :size,
          description: "Tenant payload size",
          tags: [:tenant, :message_type],
          unit: :byte,
          reporter_options: [
            buckets: [250, 500, 1000, 3000, 5000, 10_000, 25_000, 100_000, 500_000, 1_000_000, 3_000_000]
          ]
        ),
        distribution(
          [:realtime, :payload, :size],
          event_name: [:realtime, :tenants, :payload, :size],
          measurement: :size,
          description: "Payload size",
          tags: [:message_type],
          unit: :byte,
          reporter_options: [
            buckets: [250, 500, 1000, 3000, 5000, 10_000, 25_000, 100_000, 500_000, 1_000_000, 3_000_000]
          ]
        )
      ]
    )
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

  def execute_tenant_metrics do
    tenants = Tenants.list_connected_tenants(Node.self())

    for t <- tenants do
      count = UsersCounter.tenant_users(Node.self(), t)
      cluster_count = UsersCounter.tenant_users(t)
      tenant = Tenants.Cache.get_tenant_by_external_id(t)

      if tenant != nil do
        Telemetry.execute(
          [:realtime, :connections],
          %{connected: count, connected_cluster: cluster_count, limit: tenant.max_concurrent_users},
          %{tenant: t}
        )
      end
    end
  end

  defp replication_metrics do
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
            buckets: [125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
          ]
        )
      ]
    )
  end

  defp subscription_metrics do
    Event.build(
      :realtime_tenant_channel_event_metrics,
      [
        sum(
          [:realtime, :subscriptions_checker, :pid_not_found],
          event_name: [:realtime, :subscriptions_checker, :pid_not_found],
          measurement: :sum,
          description: "Sum of pids not found in Subscription tables.",
          tags: [:tenant]
        ),
        sum(
          [:realtime, :subscriptions_checker, :phantom_pid_detected],
          event_name: [:realtime, :subscriptions_checker, :phantom_pid_detected],
          measurement: :sum,
          description: "Sum of phantom pids detected in Subscription tables.",
          tags: [:tenant]
        )
      ]
    )
  end

  defp channel_events do
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
        sum(
          [:realtime, :channel, :global, :events],
          event_name: [:realtime, :rate_counter, :channel, :events],
          measurement: :sum,
          description: "Global sum of messages sent on a Realtime Channel."
        ),
        sum(
          [:realtime, :channel, :presence_events],
          event_name: [:realtime, :rate_counter, :channel, :presence_events],
          measurement: :sum,
          description: "Sum of presence messages sent on a Realtime Channel.",
          tags: [:tenant]
        ),
        sum(
          [:realtime, :channel, :global, :presence_events],
          event_name: [:realtime, :rate_counter, :channel, :presence_events],
          measurement: :sum,
          description: "Global sum of presence messages sent on a Realtime Channel."
        ),
        sum(
          [:realtime, :channel, :db_events],
          event_name: [:realtime, :rate_counter, :channel, :db_events],
          measurement: :sum,
          description: "Sum of db messages sent on a Realtime Channel.",
          tags: [:tenant]
        ),
        sum(
          [:realtime, :channel, :global, :db_events],
          event_name: [:realtime, :rate_counter, :channel, :db_events],
          measurement: :sum,
          description: "Global sum of db messages sent on a Realtime Channel."
        ),
        sum(
          [:realtime, :channel, :joins],
          event_name: [:realtime, :rate_counter, :channel, :joins],
          measurement: :sum,
          description: "Sum of Realtime Channel joins.",
          tags: [:tenant]
        ),
        last_value(
          [:realtime, :channel, :events, :limit_per_second],
          event_name: [:realtime, :rate_counter, :channel, :events],
          measurement: :limit,
          description: "Rate limit of messages per second sent on a Realtime Channel.",
          tags: [:tenant]
        ),
        last_value(
          [:realtime, :channel, :joins, :limit_per_second],
          event_name: [:realtime, :rate_counter, :channel, :joins],
          measurement: :limit,
          description: "Rate limit of joins per second on a Realtime Channel.",
          tags: [:tenant]
        ),
        distribution(
          [:realtime, :tenants, :read_authorization_check],
          event_name: [:realtime, :tenants, :read_authorization_check],
          measurement: :latency,
          unit: :millisecond,
          description: "Latency of read authorization checks.",
          tags: [:tenant],
          reporter_options: [buckets: [10, 250, 5000, 15_000]]
        ),
        distribution(
          [:realtime, :tenants, :write_authorization_check],
          event_name: [:realtime, :tenants, :write_authorization_check],
          measurement: :latency,
          unit: :millisecond,
          description: "Latency of write authorization checks.",
          tags: [:tenant],
          reporter_options: [buckets: [10, 250, 5000, 15_000]]
        ),
        distribution(
          [:realtime, :tenants, :broadcast_from_database, :latency_committed_at],
          event_name: [:realtime, :tenants, :broadcast_from_database],
          measurement: :latency_committed_at,
          unit: :millisecond,
          description: "Latency of database transaction start until reaches server to be broadcasted",
          tags: [:tenant],
          reporter_options: [buckets: [10, 250, 5000]]
        ),
        distribution(
          [:realtime, :tenants, :broadcast_from_database, :latency_inserted_at],
          event_name: [:realtime, :tenants, :broadcast_from_database],
          measurement: :latency_inserted_at,
          unit: :second,
          description: "Latency of database inserted_at until reaches server to be broadcasted",
          tags: [:tenant],
          reporter_options: [buckets: [1, 2, 5]]
        )
      ]
    )
  end
end
