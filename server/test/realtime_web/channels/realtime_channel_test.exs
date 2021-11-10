defmodule RealtimeWeb.RealtimeChannelTest do
  use RealtimeWeb.ChannelCase
  require Logger
  import Realtime.Helpers, only: [broadcast_change: 2]
  import Mock
  alias RealtimeWeb.{ChannelsAuthorization, UserSocket, RealtimeChannel}

  @token "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJzdXBhYmFzZSIsImlhdCI6MTYzMjI4MzE5MSwiZXhwIjoxNjYzODE5MjExLCJhdWQiOiJhdXRoZW50aWNhdGVkIiwic3ViIjoiYmJiNTFlNGUtZjM3MS00NDYzLWJmMGEtYWY4ZjU2ZGM5YTczIn0.imL7XhNMrS523vvdzQ93iRIw3OhjJutamLEoiZnJDbI"
  # @secret "d3v_HtNXEpT+zfsyy1LE1WPGmNKLWRfw/rpjnVtCEEM2cSFV2s+kUh5OKX7TPYmG"
  @user_id "bbb51e4e-f371-4463-bf0a-af8f56dc9a73"

  def setup_stream(_contex) do
    {:ok, _, socket} =
      socket(RealtimeWeb.UserSocket, "user_id", %{some: :assign})
      |> subscribe_and_join(RealtimeWeb.RealtimeChannel, "realtime:*")

    {:ok, socket: socket}
  end

  def setup_rls(_contex) do
    with_mock ChannelsAuthorization, authorize: fn _token -> {:ok, %{"sub" => @user_id}} end do
      {:ok, _, socket} =
        socket(UserSocket)
        |> subscribe_and_join(RealtimeChannel, "realtime:*", %{"user_token" => @token})

      {:ok, socket: socket}
    end
  end

  setup [:setup_stream, :setup_rls]

  test "INSERT message is pushed to the client" do
    change = %{
      schema: "public",
      table: "users",
      type: "INSERT"
    }

    broadcast_change("realtime:*", change)

    assert_push("INSERT", ^change)
  end

  test "UPDATE message is pushed to the client" do
    change = %{
      schema: "public",
      table: "users",
      type: "UPDATE"
    }

    broadcast_change("realtime:*", change)

    assert_push("UPDATE", ^change)
  end

  test "DELETE message is pushed to the client" do
    change = %{
      schema: "public",
      table: "users",
      type: "DELETE"
    }

    broadcast_change("realtime:*", change)

    assert_push("DELETE", ^change)
  end
end
