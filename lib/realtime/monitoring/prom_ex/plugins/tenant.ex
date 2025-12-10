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
      payload_size_metrics()
    ]
  end

  defmodule PayloadSize.Buckets do
    @moduledoc false
    use Peep.Buckets.Custom,
      buckets: [250, 500, 1000, 3000, 5000, 10_000, 25_000, 100_000, 500_000, 1_000_000, 3_000_000]
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
          reporter_options: [peep_bucket_calculator: PayloadSize.Buckets]
        ),
        distribution(
          [:realtime, :payload, :size],
          event_name: [:realtime, :tenants, :payload, :size],
          measurement: :size,
          description: "Payload size",
          tags: [:message_type],
          unit: :byte,
          reporter_options: [peep_bucket_calculator: PayloadSize.Buckets]
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
        )
      ],
      detach_on_error: false
    )
  end

  def execute_tenant_metrics do
    tenants = Tenants.list_connected_tenants(Node.self())
    cluster_counts = UsersCounter.tenant_counts()
    node_counts = UsersCounter.tenant_counts(Node.self())

    for t <- tenants do
      tenant = Tenants.Cache.get_tenant_by_external_id(t)

      if tenant != nil do
        Telemetry.execute(
          [:realtime, :connections],
          %{
            connected: Map.get(node_counts, t, 0),
            connected_cluster: Map.get(cluster_counts, t, 0),
            limit: tenant.max_concurrent_users
          },
          %{tenant: t}
        )
      end
    end
  end

  defmodule Replication.Buckets do
    @moduledoc false
    use Peep.Buckets.Custom,
      buckets: [250, 500, 1000, 3000, 5000, 10_000, 25_000, 100_000, 500_000, 1_000_000, 3_000_000]
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
          reporter_options: [peep_bucket_calculator: Replication.Buckets]
        )
      ]
    )
  end

  defmodule PolicyAuthorization.Buckets do
    @moduledoc false
    use Peep.Buckets.Custom, buckets: [10, 250, 5000, 15_000]
  end

  defmodule BroadcastFromDatabase.Buckets do
    @moduledoc false
    use Peep.Buckets.Custom, buckets: [10, 250, 5000]
  end

  defmodule Replay.Buckets do
    @moduledoc false
    use Peep.Buckets.Custom, buckets: [10, 250, 5000, 15_000]
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
        sum(
          [:realtime, :channel, :input_bytes],
          event_name: [:realtime, :channel, :input_bytes],
          description: "Sum of input bytes sent on sockets.",
          measurement: :size,
          tags: [:tenant]
        ),
        sum(
          [:realtime, :channel, :output_bytes],
          event_name: [:realtime, :channel, :output_bytes],
          description: "Sum of output bytes sent on sockets.",
          measurement: :size,
          tags: [:tenant]
        ),
        distribution(
          [:realtime, :tenants, :read_authorization_check],
          event_name: [:realtime, :tenants, :read_authorization_check],
          measurement: :latency,
          unit: :millisecond,
          description: "Latency of read authorization checks.",
          tags: [:tenant],
          reporter_options: [peep_bucket_calculator: PolicyAuthorization.Buckets]
        ),
        distribution(
          [:realtime, :tenants, :write_authorization_check],
          event_name: [:realtime, :tenants, :write_authorization_check],
          measurement: :latency,
          unit: :millisecond,
          description: "Latency of write authorization checks.",
          tags: [:tenant],
          reporter_options: [peep_bucket_calculator: PolicyAuthorization.Buckets]
        ),
        distribution(
          [:realtime, :tenants, :broadcast_from_database, :latency_committed_at],
          event_name: [:realtime, :tenants, :broadcast_from_database],
          measurement: :latency_committed_at,
          unit: :millisecond,
          description: "Latency of database transaction start until reaches server to be broadcasted",
          tags: [:tenant],
          reporter_options: [peep_bucket_calculator: BroadcastFromDatabase.Buckets]
        ),
        distribution(
          [:realtime, :tenants, :broadcast_from_database, :latency_inserted_at],
          event_name: [:realtime, :tenants, :broadcast_from_database],
          measurement: :latency_inserted_at,
          unit: {:microsecond, :millisecond},
          description: "Latency of database inserted_at until reaches server to be broadcasted",
          tags: [:tenant],
          reporter_options: [peep_bucket_calculator: BroadcastFromDatabase.Buckets]
        ),
        distribution(
          [:realtime, :tenants, :replay],
          event_name: [:realtime, :tenants, :replay],
          measurement: :latency,
          unit: :millisecond,
          description: "Latency of broadcast replay",
          tags: [:tenant],
          reporter_options: [peep_bucket_calculator: Replay.Buckets]
        )
      ]
    )
  end
end
