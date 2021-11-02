defmodule RealtimeWeb.RealtimeChannelTest do
  use RealtimeWeb.ChannelCase
  require Logger
  import Realtime.Helpers, only: [broadcast_change: 2]

  setup do
    {:ok, _, socket} =
      socket(RealtimeWeb.UserSocket, "user_id", %{some: :assign})
      |> subscribe_and_join(RealtimeWeb.RealtimeChannel, "realtime:*")

    {:ok, socket: socket}
  end

  test "INSERT message is pushed to the client" do
    change = %{
      schema: "public",
      table: "users",
      type: "INSERT"
    }

    broadcast_change("realtime:*", change)

    assert_push("INSERT", change)
  end

  test "UPDATE message is pushed to the client" do
    change = %{
      schema: "public",
      table: "users",
      type: "UPDATE"
    }

    broadcast_change("realtime:*", change)

    assert_push("UPDATE", change)
  end

  test "DELETE message is pushed to the client" do
    change = %{
      schema: "public",
      table: "users",
      type: "DELETE"
    }

    broadcast_change("realtime:*", change)

    assert_push("DELETE", change)
  end
end
