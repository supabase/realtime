defmodule RealtimeWeb.RealtimeChannelTest do
  use RealtimeWeb.ChannelCase
  require Logger

  setup do
    {:ok, _, socket} =
      socket(RealtimeWeb.UserSocket, "user_id", %{some: :assign})
      |> subscribe_and_join(RealtimeWeb.RealtimeChannel, "realtime:*")

    {:ok, socket: socket}
  end

  test "INSERTs are broadcasts to the client" do
    RealtimeWeb.RealtimeChannel.handle_realtime_transaction(
      "realtime:*",
      "INSERT",
      Jason.encode!(%{
        schema: "public",
        table: "users",
        type: "INSERT"
      })
    )

    assert_push("*", {:binary, "{\"schema\":\"public\",\"table\":\"users\",\"type\":\"INSERT\"}"})

    assert_push(
      "INSERT",
      {:binary, "{\"schema\":\"public\",\"table\":\"users\",\"type\":\"INSERT\"}"}
    )
  end

  test "UPDATEs are broadcasts to the client" do
    RealtimeWeb.RealtimeChannel.handle_realtime_transaction(
      "realtime:*",
      "UPDATE",
      Jason.encode!(%{
        schema: "public",
        table: "users",
        type: "UPDATE"
      })
    )

    assert_push("*", {:binary, "{\"schema\":\"public\",\"table\":\"users\",\"type\":\"UPDATE\"}"})

    assert_push(
      "UPDATE",
      {:binary, "{\"schema\":\"public\",\"table\":\"users\",\"type\":\"UPDATE\"}"}
    )
  end

  test "DELETEs are broadcasts to the client" do
    RealtimeWeb.RealtimeChannel.handle_realtime_transaction(
      "realtime:*",
      "DELETE",
      Jason.encode!(%{
        schema: "public",
        table: "users",
        type: "DELETE"
      })
    )

    assert_push("*", {:binary, "{\"schema\":\"public\",\"table\":\"users\",\"type\":\"DELETE\"}"})

    assert_push(
      "DELETE",
      {:binary, "{\"schema\":\"public\",\"table\":\"users\",\"type\":\"DELETE\"}"}
    )
  end
end
