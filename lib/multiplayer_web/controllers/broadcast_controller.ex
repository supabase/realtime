defmodule MultiplayerWeb.BroadcastController do
  use MultiplayerWeb, :controller

  def post(conn, %{"changes" => changes}) do
    Enum.each(changes, fn event ->
      MultiplayerWeb.Endpoint.broadcast_from!(
        self(),
        "realtime:*",
        Map.get(event, "type"),
        event
      )
    end)
    # empty response
    send_resp(conn, 200, "")
  end

  def post(conn, _), do: send_resp(conn, 400, "")

end
