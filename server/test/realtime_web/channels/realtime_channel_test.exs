defmodule RealtimeWeb.RealtimeChannelTest do
  use RealtimeWeb.ChannelCase

  setup do
    {:ok, _, socket} =
      socket(RealtimeWeb.UserSocket, "user_id", %{some: :assign})
      |> subscribe_and_join(RealtimeWeb.RealtimeChannel, "realtime")

    {:ok, socket: socket}
  end

  test "ping replies with status ok", %{socket: socket} do
    ref = push socket, "ping", %{"hello" => "there"}
    assert_reply ref, :ok, %{"hello" => "there"}
  end

  test "shout broadcasts to realtime", %{socket: socket} do
    push socket, "shdout", %{"hello" => "all"}
    assert_broadcast "shdout", %{"hello" => "all"}
  end

  test "broadcasts are pushed to the client", %{socket: socket} do
    broadcast_from! socket, "broadcast", %{"some" => "data"}
    assert_push "broadcast", %{"some" => "data"}
  end
end
