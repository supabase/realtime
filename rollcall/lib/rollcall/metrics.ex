defmodule Rollcall.Metrics do
  @moduledoc """
  The telemetry events of Rollcall.

  The functions of this module return the names of the events. Use them to
  attach a handler. Do not write the names again in another module.

  Each event has the key `scope` in its metadata. It is the scope of the tracker
  that emits the event. The events carry no other identity. In Realtime, the
  scope is the tenant, so the application chooses what to do with it.

  ## Events

    * `tracker_start/0` - a tracker started. The tracker emits the event at
      the end of `init/1`.

      Measurements: none. Metadata: `scope`.

    * `tracker_stop/0` - a tracker stops. The tracker emits the event from
      `terminate/2`.

      Measurements: none. Metadata: `scope` and `reason`. The `reason` is the
      reason that `terminate/2` receives. It is `:normal` when the grace period
      ends. It is `:shutdown` or `{:shutdown, term}` when a supervisor stops the
      tracker. Any other value is a crash. A tracker that receives the exit
      signal `:kill` runs no callback, so it emits no event.

    * `tracker_peer_purge/0` - a tick deleted a peer record, because the peer was
      silent for the silence threshold.

      Measurement: `entries`, the number of entries that left with the record.
      Metadata: `scope`, `node` and `stale`. `node` is the node of the peer.
      `stale` is `true` when `entries` is more than 0.

      A peer that stops sends a goodbye, and the goodbye removes its entries. The
      tracker keeps the empty record until the threshold, so a purge with
      `stale: false` is normal. A purge with `stale: true` means that no goodbye
      arrived, and the threshold removed the entries.

    * `tracker_peers/0` - the state of the peers after a tick. The tracker emits
      the event at the end of each tick, after it purged the silent peers.

      Measurements:

        * `count` - the number of peer records.
        * `overdue_count` - the number of peers that hold entries and have
          `silent_ticks` above 1. See `Rollcall.Tracker.Peer.overdue?/1`.
        * `max_silent_ticks` - the highest `silent_ticks` of the peers that hold
          entries. It is 0 when no peer holds entries.

      Metadata: `scope`.

      A tick counts one quiet period for each peer, and a message from the peer
      resets the count. A peer that sends one heartbeat in each period has
      `silent_ticks` 1 at each tick. A value above 1 is a missed heartbeat. The
      tracker purges the peer when the value reaches the silence threshold.
      A peer that holds no entries has nothing to lose, so the event does not
      count it in `overdue_count` or `max_silent_ticks`.
  """

  @typedoc "The name of a telemetry event."
  @type event_name :: [atom(), ...]

  @tracker_peer_purge [:rollcall, :tracker, :peer, :purge]

  @tracker_start [:rollcall, :tracker, :start]

  @tracker_stop [:rollcall, :tracker, :stop]

  @tracker_peers [:rollcall, :tracker, :peers]

  @doc "Returns the name of the event for a purge of a peer record. See the module doc."
  @spec tracker_peer_purge() :: event_name()
  def tracker_peer_purge, do: @tracker_peer_purge

  @doc "Returns the name of the event for the start of a tracker. See the module doc."
  @spec tracker_start() :: event_name()
  def tracker_start, do: @tracker_start

  @doc "Returns the name of the event for the stop of a tracker. See the module doc."
  @spec tracker_stop() :: event_name()
  def tracker_stop, do: @tracker_stop

  @doc "Returns the name of the event for the state of the peers after a tick. See the module doc."
  @spec tracker_peers() :: event_name()
  def tracker_peers, do: @tracker_peers
end
