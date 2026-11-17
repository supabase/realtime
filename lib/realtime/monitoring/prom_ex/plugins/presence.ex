defmodule Realtime.PromEx.Plugins.Presence do
  @moduledoc """
  Provides Presence related metric definitions.

  Presence metrics:
    * inter-node replication traffic, measured on the receiving node,
    * the latency from a client's track to each other subscriber being notified,
    * the latency from a client's join to its first presence_state push,
    * the duration of a client's track, untrack or update call on the presence shard,
    * periodic usage numbers (tenant/topic counts, member-count distribution)
      for each backend, tagged by `implementation`: read off Phoenix.Tracker's own
      replicated state, and read off the views of the Rollcall trackers. Both
      backends use the buckets of `Realtime.Presence.Usage`.
    * errors that occur when a tracker is running in shadow mode
  """

  alias Realtime.Presence.PhoenixUsage
  alias Realtime.Presence.Usage
  use PromEx.Plugin
  use Realtime.Logs

  @event_replication_received [:realtime, :presence, :replication, :received]
  @event_notify_latency [:realtime, :presence, :notify, :latency]
  @event_notify_discarded [:realtime, :presence, :notify, :discarded]
  @event_track_duration [:realtime, :presence, :track, :duration]
  @event_usage [:realtime, :presence, :usage]
  @event_usage_bucket [:realtime, :presence, :usage, :bucket]
  @event_join_latency [:realtime, :presence, :join, :latency]
  @event_shadow_error [:realtime, :presence, :shadow, :error]

  # Comfortably under the 60s poll interval, so a timed-out scan is never still in flight when
  # the next tick fires.
  @scan_timeout to_timeout(second: 30)

  defmodule Notify.Buckets do
    @moduledoc false
    # Dense around 1500ms: remote delivery waits for the Tracker heartbeat (broadcast_period).
    use Peep.Buckets.Custom, buckets: [5, 10, 25, 50, 100, 250, 500, 1000, 1500, 2000, 3000, 5000, 15_000]
  end

  defmodule Track.Buckets do
    @moduledoc false
    # Thresholds for a latency SLI, up to the 5s GenServer.call timeout.
    use Peep.Buckets.Custom, buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]
  end

  defmodule Scan.Buckets do
    @moduledoc false
    use Peep.Buckets.Custom, buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000]
  end

  defmodule Join.Buckets do
    @moduledoc false
    # The timer starts right at send(self(), :sync_presence) on join, so DB connection setup,
    # RLS auth and message replay (all before that point) are out of scope
    use Peep.Buckets.Custom, buckets: [5, 10, 25, 50, 100, 250, 500, 1000, 2000, 4000, 10_000, 20_000]
  end

  @impl true
  def event_metrics(_opts) do
    Event.build(:realtime_presence_event_metrics, [
      sum(
        [:realtime, :presence, :replication, :received, :bytes],
        event_name: @event_replication_received,
        measurement: :size,
        unit: :byte,
        description: "Bytes (:erlang.external_size/1) of Presence state replication received from other nodes",
        tags: [:implementation]
      ),
      counter(
        [:realtime, :presence, :replication, :received, :messages],
        event_name: @event_replication_received,
        description: "Count of the number of messages received by presence replication",
        tags: [:implementation]
      ),
      distribution(
        @event_notify_latency,
        event_name: @event_notify_latency,
        measurement: :latency,
        unit: :millisecond,
        description: "Latency from a client's presence track to another subscriber being sent the presence_diff",
        tags: [:action, :origin, :path, :implementation],
        reporter_options: [peep_bucket_calculator: Notify.Buckets]
      ),
      distribution(
        @event_track_duration,
        event_name: @event_track_duration,
        measurement: :duration,
        unit: :millisecond,
        description:
          "Duration of a client's presence track, untrack or update call on the presence shard, tagged by result (ok, error, exit) and reason",
        tags: [:action, :result, :reason, :implementation],
        reporter_options: [peep_bucket_calculator: Track.Buckets]
      ),
      counter(
        @event_notify_discarded,
        event_name: @event_notify_discarded,
        description: "Presence track latency observations discarded as clock skew (negative) or replays (stale)",
        tags: [:reason, :action, :origin, :path, :implementation]
      ),
      distribution(
        @event_join_latency,
        event_name: @event_join_latency,
        measurement: :latency,
        unit: :millisecond,
        description: "Latency from a client's channel join to receiving its first presence_state push.",
        tags: [:state, :implementation],
        reporter_options: [peep_bucket_calculator: Join.Buckets]
      ),
      counter(
        @event_shadow_error,
        event_name: @event_shadow_error,
        description: "Errors that arise from Rollcall when it is running in shadow mode",
        tags: [:operation, :reason]
      )
    ])
  end

  @impl true
  def polling_metrics(opts) do
    poll_rate = Keyword.get(opts, :poll_rate)
    rollcall = Keyword.get(opts, :rollcall, Realtime.Presence.Rollcall)

    [
      Polling.build(
        :realtime_presence_usage_metrics,
        poll_rate,
        {__MODULE__, :execute_usage_metrics, [RealtimeWeb.Presence, rollcall]},
        [
          last_value(
            [:realtime, :presence, :usage, :tenants],
            event_name: @event_usage,
            description:
              "The count of tenants with at least one live tracked presence member, tagged by implementation (phoenix or rollcall).",
            measurement: :tenant_count,
            tags: [:implementation]
          ),
          last_value(
            [:realtime, :presence, :usage, :topics],
            event_name: @event_usage,
            description:
              "The count of presence topics with at least one live tracked member, tagged by implementation (phoenix or rollcall).",
            measurement: :topic_count,
            tags: [:implementation]
          ),
          last_value(
            [:realtime, :presence, :usage, :topics_by_bucket],
            event_name: @event_usage_bucket,
            description:
              "The count of presence topics whose live member count falls in a given bucket, tagged by implementation (phoenix or rollcall).",
            measurement: :count,
            tags: [:bucket, :implementation]
          ),
          distribution(
            [:realtime, :presence, :usage, :scan, :duration, :milliseconds],
            event_name: @event_usage,
            measurement: :duration,
            unit: :millisecond,
            description:
              "Time taken to read the presence usage numbers, tagged by implementation: a scan of Phoenix.Tracker's replicated state, or a scan of the views of the Rollcall trackers.",
            tags: [:implementation],
            reporter_options: [peep_bucket_calculator: Scan.Buckets]
          )
        ],
        detach_on_error: false
      )
    ]
  end

  @doc """
  Emits usage metrics for each backend: a scan of the Phoenix `tracker`, and a scan of the views of the
  Rollcall instance `rollcall`. The events carry the `implementation` in their metadata.

  Runs each scan in an unlinked, supervised task, and waits for both with one timeout: a crash or a
  hang in a scan must never crash or wedge this poller - `:telemetry_poller` permanently
  stops calling any measurement that raises, so letting that happen here would silently kill this
  metric for the life of the node, not just for one poll. The scans run at the same time, so the
  worst case of one poll stays under the poll interval. A failure in one scan does not stop the other.

  The `catch` below exists for the same reason, one level up: `Task.Supervisor.async_nolink/2`
  itself exits (not raises) if `Realtime.TaskSupervisor` isn't registered yet, which `rescue`
  doesn't catch. `Realtime.PromEx` normally starts after `Realtime.TaskSupervisor` in the
  application's supervision tree, so this shouldn't fire in practice - but relying solely on
  supervision-tree order here is exactly the kind of assumption that's easy to break without
  noticing, so this is a second layer of defence.
  """
  def execute_usage_metrics(tracker, rollcall) do
    scans = [phoenix: fn -> PhoenixUsage.scan(tracker) end, rollcall: fn -> rollcall_usage(rollcall) end]

    Realtime.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      scans,
      fn {implementation, scan} -> scan_and_measure(implementation, scan) end,
      timeout: @scan_timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.each(&log_scan_failure/1)
  catch
    :exit, reason -> log_error("PresenceUsageScanSetupFailed", reason)
  end

  defp log_scan_failure({:ok, :ok}), do: :ok

  defp log_scan_failure({:exit, {{implementation, _scan}, :timeout}}) do
    log_error(
      "PresenceUsageScanTimeout",
      "#{implementation}: Presence usage scan did not complete within #{@scan_timeout}ms"
    )
  end

  defp log_scan_failure({:exit, {{implementation, _scan}, reason}}),
    do: log_error("PresenceUsageScanCrashed", "#{implementation}: #{inspect(reason)}")

  # A Rollcall scope is a tenant and a Rollcall partition is a topic.
  defp rollcall_usage(rollcall) do
    %{scope_count: scope_count, partition_count: partition_count, entry_count_buckets: buckets} =
      Rollcall.usage(rollcall, Usage.buckets())

    %{tenant_count: scope_count, topic_count: partition_count, buckets: buckets}
  end

  defp scan_and_measure(implementation, scan) do
    start = System.monotonic_time()
    usage = scan.()
    duration = System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)

    measurements = usage |> Map.take([:tenant_count, :topic_count]) |> Map.put(:duration, duration)
    :telemetry.execute(@event_usage, measurements, %{implementation: implementation})

    Enum.each(usage.buckets, fn {bucket, count} ->
      :telemetry.execute(@event_usage_bucket, %{count: count}, %{bucket: bucket, implementation: implementation})
    end)

    :ok
  end
end
