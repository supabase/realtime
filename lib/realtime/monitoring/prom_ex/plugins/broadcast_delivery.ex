defmodule Realtime.PromEx.Plugins.BroadcastDelivery do
  @moduledoc false
  use PromEx.Plugin

  alias RealtimeWeb.BroadcastDeliveryMetrics

  defmodule Buckets do
    @moduledoc false
    # Peep renders the bounds as floats, so the le labels are "10.0" ... "1.0e3", "2.5e3", "5.0e3", "1.0e4".
    use Peep.Buckets.Custom,
      buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
  end

  @impl true
  def event_metrics(_opts) do
    Event.build(:realtime_broadcast_delivery_metrics, [
      distribution(
        [:realtime, :broadcast, :delivery, :latency],
        event_name: BroadcastDeliveryMetrics.event(),
        measurement: :latency,
        unit: {:native, :microsecond},
        description:
          "Time from the start of a tenant broadcast's local dispatch to the last subscriber socket it was sent to, one sample per message per node when at least one socket received it, by origin (local: published on this node, remote: received from another node). Excludes the hop between nodes, mailbox waits and the socket write.",
        tags: [:origin],
        reporter_options: [peep_bucket_calculator: Buckets]
      )
    ])
  end
end
