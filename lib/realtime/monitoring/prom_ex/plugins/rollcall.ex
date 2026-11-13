defmodule Realtime.PromEx.Plugins.Rollcall do
  @moduledoc """
  A PromEx plugin that turns the telemetry events of Rollcall into metrics.

  The event names and their measurements are in `Rollcall.Metrics`. The events carry the scope of the
  tracker, which is a tenant. No metric has a tenant label or a scope label, so the cardinality stays
  low and the metrics belong in the global `Realtime.PromEx` registry.

  ## Metrics

    * `realtime_rollcall_tracker_started` - trackers that started.
    * `realtime_rollcall_tracker_stopped` - trackers that stopped, by `reason`: `normal`, `shutdown`
      or `crash`. The plugin maps the reason of the event, which can be any term.
    * `realtime_rollcall_peer_purged` - peer records that a tracker deleted, by `stale`. A purge with
      `stale=false` is normal, because the goodbye of the peer already removed its entries.
    * `realtime_rollcall_peer_silent_ticks` - a distribution of the highest `silent_ticks` over the
      peers that hold entries. The tracker takes one observation at each tick.
    * `realtime_rollcall_peer_observations` - the peers that the trackers held, counted at each tick.
    * `realtime_rollcall_peer_observations_overdue` - the peer observations of a peer that holds
      entries and missed a heartbeat. The share of this sum in the observations is the share of
      overdue peers.
    * `realtime_rollcall_heartbeat_send_duration` - a distribution, in microseconds, of the time that
      a tracker spends to build a heartbeat and to call the transport, by `kind` of the message.
    * `realtime_rollcall_heartbeat_apply_duration` - a distribution, in microseconds, of the time that
      a tracker spends to apply a message from a peer, by `kind` of the message: `snapshot`, `diff` or
      `request`. It does not include the publish.
    * `realtime_rollcall_publish_duration` - a distribution, in microseconds, of one call to publish
      the changes of a partition, by `source`: `local`, `peer` or `purge`. It depends on the
      subscribers of the partition, so it is apart from the apply duration.
    * `realtime_rollcall_heartbeat_send_entries` - a distribution of the entries in each heartbeat
      that a tracker sends, by `kind`. A snapshot holds all the local entries of the tracker.
    * `realtime_rollcall_publish_entries` - the joins and the leaves that trackers publish, by
      `source`. It is the churn of the entries.
    * `realtime_rollcall_tracker_entries` - a distribution of the entries in the view of a tracker:
      the local entries plus the entries of the peers. The tracker takes one observation at each tick.
    * `realtime_rollcall_tracker_process_bytes` - a distribution of the memory of a tracker process,
      in bytes. A value above 100 MB counts in the `+Inf` bucket only.
    * `realtime_rollcall_tracker_ets_bytes` - a distribution of the memory of the view table of a
      tracker, in bytes. A value above 100 MB counts in the `+Inf` bucket only.
    * `realtime_rollcall_tracker_reductions` - a distribution of the reductions that a tracker process
      used since its previous tick.
    * `realtime_rollcall_trackers` - a gauge of the trackers that run on this node. The plugin polls
      the Registry of the Rollcall instance. The option `:rollcall` sets the instance. The default
      is `Realtime.Presence.Rollcall`.

  The events carry each `duration` in native time units, and the plugin converts it to microseconds.
  """
  use PromEx.Plugin

  @event_trackers [:prom_ex, :plugin, :rollcall, :trackers]

  defmodule SilentTicks.Buckets do
    @moduledoc false
    # The values are whole ticks. Peep puts a value in a bucket only when the value is below the
    # bound, so a bound equal to a value would put that value in the next bucket. Each bound is half
    # a tick above the value it stands for: 0, 1, 2, 3, 5, 7, 9 and 10 ticks. A healthy peer has 1 silent
    # tick at each tick. The tracker purges a peer at the silence threshold, which is 10 ticks by default.
    use Peep.Buckets.Custom, buckets: [0.5, 1.5, 2.5, 3.5, 5.5, 7.5, 9.5, 10.5]
  end

  defmodule Duration.Buckets do
    @moduledoc false
    # Microseconds. A send calls the PubSub and can take milliseconds. A publish depends on the number
    # of subscribers of the partition.
    use Peep.Buckets.Custom, buckets: [10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 100_000]
  end

  defmodule Entries.Buckets do
    @moduledoc false
    # The values are whole entries. Peep puts a value in a bucket only when the value is below the
    # bound, so each bound is half an entry above the value it stands for. An empty heartbeat, from a
    # tracker with no local entry, has its own bucket.
    use Peep.Buckets.Custom, buckets: [0.5, 1.5, 5.5, 10.5, 50.5, 100.5, 500.5, 1_000.5, 5_000.5, 10_000.5]
  end

  defmodule Bytes.Buckets do
    @moduledoc false
    # Bytes. An idle tracker process uses about 10 to 20 KB. The view table of a tracker with no entry
    # uses about 1 KB. Both grow with the number of entries. A value above the last bound counts in
    # the `+Inf` bucket only.
    use Peep.Buckets.Custom,
      buckets: [
        1_000,
        10_000,
        50_000,
        100_000,
        500_000,
        1_000_000,
        5_000_000,
        10_000_000,
        50_000_000,
        100_000_000
      ]
  end

  defmodule Reductions.Buckets do
    @moduledoc false
    # Reductions of one tick, in powers of ten. The bounds are a first guess. Adjust them when the
    # metric has data.
    use Peep.Buckets.Custom, buckets: [100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000]
  end

  @impl true
  def event_metrics(_opts) do
    Event.build(:realtime_rollcall_event_metrics, [
      counter(
        [:realtime, :rollcall, :tracker, :started],
        event_name: Rollcall.Metrics.tracker_start(),
        description: "Rollcall trackers that started on this node."
      ),
      counter(
        [:realtime, :rollcall, :tracker, :stopped],
        event_name: Rollcall.Metrics.tracker_stop(),
        description:
          "Rollcall trackers that stopped on this node, tagged by reason: normal (the grace period ended), shutdown (a supervisor stopped the tracker) or crash.",
        tags: [:reason],
        tag_values: &stop_tag_values/1
      ),
      counter(
        [:realtime, :rollcall, :peer, :purged],
        event_name: Rollcall.Metrics.tracker_peer_purge(),
        description:
          "Peer records that a Rollcall tracker deleted after the silence threshold, tagged by stale. stale=false is normal: the peer said goodbye. stale=true means no goodbye arrived, and the entries of the peer left with the record.",
        tags: [:stale]
      ),
      distribution(
        [:realtime, :rollcall, :peer, :silent, :ticks],
        event_name: Rollcall.Metrics.tracker_peers(),
        measurement: :max_silent_ticks,
        description:
          "The highest number of ticks without a message over the peers that hold entries, for each Rollcall tracker at each tick. A healthy peer has 1. The tracker purges a peer at the silence threshold.",
        reporter_options: [peep_bucket_calculator: SilentTicks.Buckets]
      ),
      sum(
        [:realtime, :rollcall, :peer, :observations],
        event_name: Rollcall.Metrics.tracker_peers(),
        measurement: :count,
        description: "The peers that Rollcall trackers held, counted for each tracker at each tick."
      ),
      sum(
        [:realtime, :rollcall, :peer, :observations, :overdue],
        event_name: Rollcall.Metrics.tracker_peers(),
        measurement: :overdue_count,
        description:
          "Peer observations where the peer holds entries and missed a heartbeat. Divide by realtime_rollcall_peer_observations for the share of overdue peers."
      ),
      distribution(
        [:realtime, :rollcall, :heartbeat, :send, :duration],
        event_name: Rollcall.Metrics.tracker_heartbeat_send(),
        measurement: :duration,
        unit: {:native, :microsecond},
        description:
          "Time that a Rollcall tracker spends to send a heartbeat, in microseconds, tagged by the kind of the message (snapshot or diff). It builds the message and calls the transport.",
        tags: [:kind],
        reporter_options: [peep_bucket_calculator: Duration.Buckets]
      ),
      distribution(
        [:realtime, :rollcall, :heartbeat, :apply, :duration],
        event_name: Rollcall.Metrics.tracker_heartbeat_apply(),
        measurement: :duration,
        unit: {:native, :microsecond},
        description:
          "Time that a Rollcall tracker spends to apply a message from a peer, in microseconds, tagged by the kind of the message (snapshot, diff or request). It changes the peer record, the replica and the view, and does not include the publish. The event also carries the node of the peer, which is not a tag.",
        tags: [:kind],
        reporter_options: [peep_bucket_calculator: Duration.Buckets]
      ),
      distribution(
        [:realtime, :rollcall, :publish, :duration],
        event_name: Rollcall.Metrics.tracker_publish(),
        measurement: :duration,
        unit: {:native, :microsecond},
        description:
          "Time of one call that publishes the changes of a Rollcall partition, in microseconds, tagged by source (local, peer or purge). It depends on the subscribers of the partition.",
        tags: [:source],
        reporter_options: [peep_bucket_calculator: Duration.Buckets]
      ),
      distribution(
        [:realtime, :rollcall, :heartbeat, :send, :entries],
        event_name: Rollcall.Metrics.tracker_heartbeat_send(),
        measurement: :entries,
        description:
          "The entries in each heartbeat that a Rollcall tracker sends, tagged by the kind of the message (snapshot or diff). A snapshot holds all the local entries of the tracker.",
        tags: [:kind],
        reporter_options: [peep_bucket_calculator: Entries.Buckets]
      ),
      sum(
        [:realtime, :rollcall, :publish, :entries],
        event_name: Rollcall.Metrics.tracker_publish(),
        measurement: :entries,
        description:
          "The joins and the leaves that Rollcall trackers publish, tagged by source: local (clients), peer (a message from a peer) or purge (a peer that was purged).",
        tags: [:source]
      ),
      distribution(
        [:realtime, :rollcall, :tracker, :entries],
        event_name: Rollcall.Metrics.tracker_usage(),
        measurement: :entries,
        description:
          "The entries in the view of a Rollcall tracker, counted at each tick: the local entries plus the entries of the peers.",
        reporter_options: [peep_bucket_calculator: Entries.Buckets]
      ),
      distribution(
        [:realtime, :rollcall, :tracker, :process, :bytes],
        event_name: Rollcall.Metrics.tracker_usage(),
        measurement: :process_bytes,
        description:
          "The memory of a Rollcall tracker process, in bytes, counted at each tick. It is the memory value of Process.info/2: the heap, the stack and the mailbox.",
        reporter_options: [peep_bucket_calculator: Bytes.Buckets]
      ),
      distribution(
        [:realtime, :rollcall, :tracker, :ets, :bytes],
        event_name: Rollcall.Metrics.tracker_usage(),
        measurement: :ets_bytes,
        description: "The memory of the view table of a Rollcall tracker, in bytes, counted at each tick.",
        reporter_options: [peep_bucket_calculator: Bytes.Buckets]
      ),
      distribution(
        [:realtime, :rollcall, :tracker, :reductions],
        event_name: Rollcall.Metrics.tracker_usage(),
        measurement: :reductions,
        description:
          "The reductions that a Rollcall tracker process used since its previous tick. It measures the CPU work of a tracker in each period.",
        reporter_options: [peep_bucket_calculator: Reductions.Buckets]
      )
    ])
  end

  @impl true
  def polling_metrics(opts) do
    poll_rate = Keyword.get(opts, :poll_rate)
    rollcall = Keyword.get(opts, :rollcall, Realtime.Presence.Rollcall)

    [
      Polling.build(
        :realtime_rollcall_polling_metrics,
        poll_rate,
        {__MODULE__, :execute_metrics, [rollcall]},
        [
          last_value(
            [:realtime, :rollcall, :trackers],
            event_name: @event_trackers,
            description: "The Rollcall trackers that run on this node. Each tenant with presence has one tracker.",
            measurement: :count
          )
        ],
        detach_on_error: false
      )
    ]
  end

  @doc """
  Emits the number of running trackers of the Rollcall instance `rollcall`.

  `:telemetry_poller` stops a measurement for good after it raises once. `Registry.count/1` raises
  when the Registry of the instance is not running, so the function emits no event in that case.
  """
  def execute_metrics(rollcall) do
    :telemetry.execute(@event_trackers, %{count: Registry.count(rollcall)}, %{})
  rescue
    ArgumentError -> :ok
  end

  # The reason of a stop is the exit reason of the tracker, which can be any term. The tag has three
  # values.
  defp stop_tag_values(%{reason: reason}), do: %{reason: stop_reason(reason)}

  defp stop_reason(:normal), do: :normal
  defp stop_reason(:shutdown), do: :shutdown
  defp stop_reason({:shutdown, _}), do: :shutdown
  defp stop_reason(_reason), do: :crash
end
