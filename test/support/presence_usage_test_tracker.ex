defmodule Realtime.Test.PresenceUsageTracker do
  @moduledoc """
  A standalone `Phoenix.Presence` instance for `RealtimeWeb.Presence.Usage` tests.

  `Phoenix.Presence.start_link/3` always registers under the using module's own name, so
  `RealtimeWeb.Presence` can't be started twice under different names. This is a separate
  module using the same real `Phoenix.Presence`/`Phoenix.Tracker` mechanics, giving each test
  its own ETS-table namespace and shard pool via `start_supervised!({__MODULE__, pool_size: n})`.
  """
  use Phoenix.Presence,
    otp_app: :realtime,
    pubsub_server: Realtime.PubSub,
    dispatcher: RealtimeWeb.RealtimeChannel.MessageDispatcher
end
