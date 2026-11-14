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
  """
  use PromEx.Plugin

  defmodule SilentTicks.Buckets do
    @moduledoc false
    # The values are whole ticks. Peep puts a value in a bucket only when the value is below the
    # bound, so a bound equal to a value would put that value in the next bucket. Each bound is half
    # a tick above the value it stands for: 0, 1, 2, 3, 5, 7, 9 and 10 ticks. A healthy peer has 1 silent
    # tick at each tick. The tracker purges a peer at the silence threshold, which is 10 ticks by default.
    use Peep.Buckets.Custom, buckets: [0.5, 1.5, 2.5, 3.5, 5.5, 7.5, 9.5, 10.5]
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
      )
    ])
  end

  # The reason of a stop is the exit reason of the tracker, which can be any term. The tag has three
  # values.
  defp stop_tag_values(%{reason: reason}), do: %{reason: stop_reason(reason)}

  defp stop_reason(:normal), do: :normal
  defp stop_reason(:shutdown), do: :shutdown
  defp stop_reason({:shutdown, _}), do: :shutdown
  defp stop_reason(_reason), do: :crash
end
