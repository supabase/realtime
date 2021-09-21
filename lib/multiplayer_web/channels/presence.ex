defmodule MultiplayerWeb.Presence do
  @moduledoc """
  Provides presence tracking to channels and processes.

  See the [`Phoenix.Presence`](http://hexdocs.pm/phoenix/Phoenix.Presence.html)
  docs for more details.
  """
  use Phoenix.Presence, otp_app: :multiplayer,
                        pubsub_server: Multiplayer.PubSub,
                        pool_size: 10
end
