defmodule Realtime.PromEx.Plugins.Presence do
  @moduledoc """
  Provides Presence related metric definitions.

  Presence metrics:
    * inter-node replication traffic, measured on the receiving node,
    * the latency from a client's track to each other subscriber being notified,
    * the latency from a client's join to its first presence_state push,
    * periodic usage numbers (tenant/topic counts, member-count distribution)
      read off Phoenix.Tracker's own replicated state.
  """

  alias RealtimeWeb.Presence
  use PromEx.Plugin
  use Realtime.Logs

  @event_replication_received [:realtime, :presence, :replication, :received]
  @event_notify_latency [:realtime, :presence, :notify, :latency]
  @event_notify_discarded [:realtime, :presence, :notify, :discarded]
  @event_usage [:realtime, :presence, :usage]
  @event_usage_bucket [:realtime, :presence, :usage, :bucket]
  @event_join_latency [:realtime, :presence, :join, :latency]

  # Comfortably under the 60s poll interval, so a timed-out scan is never still in flight when
  # the next tick fires.
  @scan_timeout to_timeout(second: 30)

  defmodule Notify.Buckets do
    @moduledoc false
    # Dense around 1500ms: remote delivery waits for the Tracker heartbeat (broadcast_period).
    use Peep.Buckets.Custom, buckets: [5, 10, 25, 50, 100, 250, 500, 1000, 1500, 2000, 3000, 5000, 15_000]
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
      distribution(
        @event_notify_latency,
        event_name: @event_notify_latency,
        measurement: :latency,
        unit: :millisecond,
        description: "Latency from a client's presence track to another subscriber being sent the presence_diff",
        tags: [:action, :origin, :path, :implementation],
        reporter_options: [peep_bucket_calculator: Notify.Buckets]
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
      )
    ])
  end

  @impl true
  def polling_metrics(opts) do
    poll_rate = Keyword.get(opts, :poll_rate)

    [
      Polling.build(
        :realtime_presence_usage_metrics,
        poll_rate,
        {__MODULE__, :execute_usage_metrics, [RealtimeWeb.Presence]},
        [
          last_value(
            [:realtime, :presence, :usage, :tenants],
            event_name: @event_usage,
            description: "The count of tenants with at least one live tracked presence member.",
            measurement: :tenant_count
          ),
          last_value(
            [:realtime, :presence, :usage, :topics],
            event_name: @event_usage,
            description: "The count of presence topics with at least one live tracked member.",
            measurement: :topic_count
          ),
          last_value(
            [:realtime, :presence, :usage, :topics_by_bucket],
            event_name: @event_usage_bucket,
            description: "The count of presence topics whose live member count falls in a given bucket.",
            measurement: :count,
            tags: [:bucket]
          ),
          distribution(
            [:realtime, :presence, :usage, :scan, :duration, :milliseconds],
            event_name: @event_usage,
            measurement: :duration,
            unit: :millisecond,
            description: "Time taken to scan Phoenix.Tracker's replicated state for presence usage metrics.",
            reporter_options: [peep_bucket_calculator: Scan.Buckets]
          )
        ],
        detach_on_error: false
      )
    ]
  end

  @doc """
  Emits usage metrics by scanning presence buckets.

  Runs the scan in an unlinked, supervised task with a timeout: a crash or a hang in
  `Presence.Usage.scan/1` must never crash or wedge this poller - `:telemetry_poller` permanently
  stops calling any measurement that raises, so letting that happen here would silently kill this
  metric for the life of the node, not just for one poll.

  The `catch` below exists for the same reason, one level up: `Task.Supervisor.async_nolink/2`
  itself exits (not raises) if `Realtime.TaskSupervisor` isn't registered yet, which `rescue`
  doesn't catch. `Realtime.PromEx` normally starts after `Realtime.TaskSupervisor` in the
  application's supervision tree, so this shouldn't fire in practice - but relying solely on
  supervision-tree order here is exactly the kind of assumption that's easy to break without
  noticing, so this is a second layer of defence.
  """
  def execute_usage_metrics(tracker) do
    task = Task.Supervisor.async_nolink(Realtime.TaskSupervisor, fn -> scan_and_measure(tracker) end)

    case Task.yield(task, @scan_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        :ok

      {:exit, reason} ->
        log_error("PresenceUsageScanCrashed", reason)

      nil ->
        log_error("PresenceUsageScanTimeout", "Presence usage scan did not complete within #{@scan_timeout}ms")
    end
  catch
    :exit, reason -> log_error("PresenceUsageScanSetupFailed", reason)
  end

  defp scan_and_measure(tracker) do
    start = System.monotonic_time()
    scan = Presence.Usage.scan(tracker)
    duration = System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)

    measurements = scan |> Map.take([:tenant_count, :topic_count]) |> Map.put(:duration, duration)
    :telemetry.execute(@event_usage, measurements)

    Enum.each(scan.buckets, fn {bucket, count} ->
      :telemetry.execute(@event_usage_bucket, %{count: count}, %{bucket: bucket})
    end)

    :ok
  end
end
