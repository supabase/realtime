defmodule RealtimeWeb.RealtimeChannelTest do
  use RealtimeWeb.ChannelCase
  require Logger
  import Realtime.Helpers, only: [broadcast_change: 2]
  import Mock
  alias Phoenix.Socket
  alias Phoenix.Socket.Broadcast
  alias RealtimeWeb.{ChannelsAuthorization, UserSocket, RealtimeChannel}

  @claims %{"role" => "authenticated"}

  setup do
    with_mock ChannelsAuthorization,
      authorize: fn _token -> {:ok, @claims} end do
      {:ok, _, socket} =
        UserSocket
        |> socket("", %{access_token: "access_token"})
        |> subscribe_and_join(RealtimeChannel, "realtime:*", %{"user_token" => "token123"})

      %{socket: socket}
    end
  end

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

  test "join channel when token is valid but does not contain claims" do
    with_mock ChannelsAuthorization,
      authorize: fn _token -> {:ok, %{}} end do
      assert {:ok, _, _} =
               UserSocket
               |> socket()
               |> subscribe_and_join(RealtimeChannel, "realtime:*", %{"user_token" => "token123"})
    end
  end

  test "join channel when token is invalid" do
    with_mock ChannelsAuthorization,
      authorize: fn _token -> :error end do
      assert {:error, %{reason: "error occurred when joining realtime:* with user token"}} =
               UserSocket
               |> socket("", %{access_token: "access_token"})
               |> subscribe_and_join(RealtimeChannel, "realtime:*", %{"user_token" => "token123"})
    end
  end

  test "handle_info/sync_subscription, when access token exists" do
    with_mock ChannelsAuthorization,
      authorize: fn _token -> {:ok, @claims} end do
      socket =
        UserSocket
        |> socket()
        |> subscribe_and_join(RealtimeChannel, "realtime:*", %{"user_token" => "token123"})

      assert {:noreply, _} =
               RealtimeChannel.handle_info(
                 %Broadcast{
                   event: "sync_subscription",
                   topic: "subscription_manager"
                 },
                 socket
               )
    end
  end

  test "handle_info/sync_subscription, when access token does not exist" do
    with_mock ChannelsAuthorization,
      authorize: fn _token -> {:ok, @claims} end do
      socket =
        UserSocket
        |> socket()
        |> subscribe_and_join(RealtimeChannel, "realtime:*", %{})

      assert {:noreply, _} =
               RealtimeChannel.handle_info(
                 %Broadcast{
                   event: "sync_subscription",
                   topic: "subscription_manager"
                 },
                 socket
               )
    end
  end

  test "handle_info/verify_access_token, when access token is valid", %{socket: socket} do
    with_mock ChannelsAuthorization,
      authorize: fn _token -> {:ok, @claims} end do
      assert {:noreply, %Socket{assigns: %{verify_ref: new_ref}}} =
               RealtimeChannel.handle_info(:verify_access_token, socket)

      assert socket.assigns.verify_ref != new_ref
    end
  end

  test "handle_info/verify_access_token, when access token is invalid", %{socket: socket} do
    with_mock ChannelsAuthorization,
      authorize: fn _token -> :error end do
      assert {:stop, :invalid_access_token, _} =
               RealtimeChannel.handle_info(:verify_access_token, socket)
    end
  end

  test "client sends valid access token", %{socket: socket} do
    with_mock ChannelsAuthorization,
      authorize: fn _token -> {:ok, @claims} end do
      push(socket, "access_token", %{"access_token" => "fresh_token_123"})

      assert %Socket{assigns: %{access_token: "fresh_token_123"}} =
               :sys.get_state(socket.channel_pid)
    end
  end

  test "client sends invalid access token", %{socket: socket} do
    with_mock ChannelsAuthorization,
      authorize: fn _token -> :error end do
      Process.unlink(socket.channel_pid)

      push(socket, "access_token", %{"access_token" => "fresh_token_123"})

      assert :ok = close(socket)
    end
  end
end
