defmodule Realtime.PromEx.Plugins.Presence do
  @moduledoc """
  Presence metrics: inter-node replication traffic, measured on the receiving node, and the
  latency from a client's track to each other subscriber being notified.
  """

  use PromEx.Plugin

  @event_replication_received [:realtime, :presence, :replication, :received]
  @event_notify_latency [:realtime, :presence, :notify, :latency]
  @event_notify_discarded [:realtime, :presence, :notify, :discarded]

  defmodule Notify.Buckets do
    @moduledoc false
    # Dense around 1500ms: remote delivery waits for the Tracker heartbeat (broadcast_period).
    use Peep.Buckets.Custom, buckets: [5, 10, 25, 50, 100, 250, 500, 1000, 1500, 2000, 3000, 5000, 15_000]
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
      )
    ])
  end
end
