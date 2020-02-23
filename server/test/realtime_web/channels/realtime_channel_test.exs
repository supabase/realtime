defmodule RealtimeWeb.RealtimeChannelTest do
  use RealtimeWeb.ChannelCase

  setup do
    {:ok, _, socket} =
      socket(RealtimeWeb.UserSocket, "user_id", %{some: :assign})
      |> subscribe_and_join(RealtimeWeb.RealtimeChannel, "realtime:*")

    {:ok, socket: socket}
  end

  test "shout broadcasts to realtime", %{socket: socket} do
    push socket, "*", %{"hello" => "all"}
    assert_broadcast "*", %{"hello" => "all"}
  end

  test "broadcasts are pushed to the client", %{socket: socket} do
    broadcast_from! socket, "broadcast", %{"some" => "data"}
    assert_push "broadcast", %{"some" => "data"}
  end
end
