defmodule RealtimeWeb.RealtimeChannelTest do
  use RealtimeWeb.ChannelCase
  require Logger
  import Realtime.Helpers, only: [broadcast_change: 2]
  import Mock
  alias RealtimeWeb.{ChannelsAuthorization, UserSocket, RealtimeChannel}

  @token "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJzdXBhYmFzZSIsImlhdCI6MTYzNzExMzE1NywiZXhwIjoxNjY4NjQ5MTYwLCJhdWQiOiJhdXRoZW50aWNhdGVkIiwic3ViIjoiYmJiNTFlNGUtZjM3MS00NDYzLWJmMGEtYWY4ZjU2ZGM5YTczIiwiZW1haWwiOiJ1c2VyQHRlc3QuY29tIn0.oENgF1oeGzXErP2Ro0mt8aMltiaBFil5S5KrHbm7RfY"
  @user_id "bbb51e4e-f371-4463-bf0a-af8f56dc9a73"
  @user_email "user@test.com"

  def setup_stream(_context) do
    {:ok, _, socket} =
      socket(RealtimeWeb.UserSocket, "user_id", %{some: :assign})
      |> subscribe_and_join(RealtimeWeb.RealtimeChannel, "realtime:*")

    {:ok, socket: socket}
  end

  def setup_rls(_context) do
    with_mock ChannelsAuthorization,
      authorize: fn _token -> {:ok, %{"sub" => @user_id, "email" => @user_email}} end do
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
