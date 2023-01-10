defmodule RealtimeWeb.RealtimeChannelTest do
  use ExUnit.Case, async: false
  use RealtimeWeb.ChannelCase

  import Mock

  alias Phoenix.Socket
  alias RealtimeWeb.{ChannelsAuthorization, Joken.CurrentTime, UserSocket}

  @tenant "dev_tenant"

  @default_limits %{
    max_concurrent_users: 200,
    max_events_per_second: 100,
    max_joins_per_second: 500,
    max_channels_per_client: 100,
    max_bytes_per_second: 100_000
  }

  setup do
    {:ok, _pid} = start_supervised(CurrentTime.Mock)
    :ok
  end

  describe "maximum number of connected clients per tenant" do
    test "not reached" do
      with_mocks([
        {ChannelsAuthorization, [],
         [
           authorize_conn: fn _, _ ->
             {:ok, %{"exp" => Joken.current_time() + 1_000, "role" => "postgres"}}
           end
         ]}
      ]) do
        {:ok, %Socket{} = socket} =
          connect(UserSocket, %{}, %{
            uri: %{host: "#{@tenant}.localhost:4000/socket/websocket", query: ""},
            x_headers: [{"x-api-key", "token123"}]
          })

        socket = Socket.assign(socket, %{limits: %{@default_limits | max_concurrent_users: 1}})
        assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
      end
    end

    test "reached" do
      with_mocks([
        {ChannelsAuthorization, [],
         [
           authorize_conn: fn _, _ ->
             {:ok, %{"exp" => Joken.current_time() + 1_000, "role" => "postgres"}}
           end
         ]}
      ]) do
        {:ok, %Socket{} = socket} =
          connect(UserSocket, %{}, %{
            uri: %{host: "#{@tenant}.localhost:4000/socket/websocket", query: ""},
            x_headers: [{"x-api-key", "token123"}]
          })

        socket_at_capacity =
          Socket.assign(socket, %{limits: %{@default_limits | max_concurrent_users: 0}})

        socket_over_capacity =
          Socket.assign(socket, %{limits: %{@default_limits | max_concurrent_users: -1}})

        assert {:error, %{reason: "{:error, :too_many_connections}"}} =
                 subscribe_and_join(socket_at_capacity, "realtime:test", %{})

        assert {:error, %{reason: "{:error, :too_many_connections}"}} =
                 subscribe_and_join(socket_over_capacity, "realtime:test", %{})
      end
    end
  end

  describe "token expiration" do
    test "valid" do
      with_mocks([
        {ChannelsAuthorization, [],
         [
           authorize_conn: fn _, _ ->
             {:ok, %{"exp" => Joken.current_time() + 1, "role" => "postgres"}}
           end
         ]}
      ]) do
        {:ok, %Socket{} = socket} =
          connect(UserSocket, %{}, %{
            uri: %{host: "#{@tenant}.localhost:4000/socket/websocket", query: ""},
            x_headers: [{"x-api-key", "token123"}]
          })

        assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
      end
    end

    test "invalid" do
      with_mocks([
        {ChannelsAuthorization, [],
         [
           authorize_conn: fn _, _ ->
             {:ok, %{"exp" => Joken.current_time(), "role" => "postgres"}}
           end
         ]}
      ]) do
        {:ok, %Socket{} = socket} =
          connect(UserSocket, %{}, %{
            uri: %{host: "#{@tenant}.localhost:4000/socket/websocket", query: ""},
            x_headers: [{"x-api-key", "token123"}]
          })

        assert {:error, %{reason: "{:error, 0}"}} =
                 subscribe_and_join(socket, "realtime:test", %{})
      end

      with_mocks([
        {ChannelsAuthorization, [],
         [
           authorize_conn: fn _, _ ->
             {:ok, %{"exp" => Joken.current_time() - 1, "role" => "postgres"}}
           end
         ]}
      ]) do
        {:ok, %Socket{} = socket} =
          connect(UserSocket, %{}, %{
            uri: %{host: "#{@tenant}.localhost:4000/socket/websocket", query: ""},
            x_headers: [{"x-api-key", "token123"}]
          })

        assert {:error, %{reason: "{:error, -1}"}} =
                 subscribe_and_join(socket, "realtime:test", %{})
      end
    end
  end
end
