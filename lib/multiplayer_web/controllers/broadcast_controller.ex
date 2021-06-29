defmodule MultiplayerWeb.BroadcastController do
  use MultiplayerWeb, :controller

  def post(conn, %{"changes" => changes, "scope" => scope, "topic" => topic}) do
    Enum.each(changes, fn event ->
      Phoenix.PubSub.broadcast(
        Multiplayer.PubSub,
        scope <> ":" <> topic,
        {:event, event}
      )
    end)
    # empty response
    send_resp(conn, 200, "")
  end

  def post(conn, _), do: send_resp(conn, 400, "")

end
