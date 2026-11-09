defmodule Realtime.Presence.Rollcall do
  @moduledoc """
  The Rollcall instance of Realtime. `Realtime.Presence.RollcallBackend` calls it.

  The scope is the tenant id and the partition is the tenant topic.
  """
  use Rollcall,
    transport: {Realtime.Presence.RollcallTransport, pubsub: Realtime.PubSub}
end
