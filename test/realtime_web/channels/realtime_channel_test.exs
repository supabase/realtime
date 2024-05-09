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
    max_joins_per_second: 100,
    max_channels_per_client: 100,
    max_bytes_per_second: 100_000
  }

  @default_conn_opts [
    connect_info: %{
      uri: %{host: "#{@tenant}.localhost:4000/socket/websocket", query: ""},
      x_headers: [{"x-api-key", "token123"}]
    }
  ]

  setup do
    start_supervised!(CurrentTime.Mock)
    :ok
  end

  describe "maximum number of connected clients per tenant" do
    test "not reached" do
      with_mocks([
        {ChannelsAuthorization, [],
         [
           authorize_conn: fn _, _, _ ->
             {:ok, %{"exp" => Joken.current_time() + 1_000, "role" => "postgres"}}
           end
         ]}
      ]) do
        {:ok, %Socket{} = socket} = connect(UserSocket, %{}, @default_conn_opts)

        socket = Socket.assign(socket, %{limits: %{@default_limits | max_concurrent_users: 1}})
        assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
      end
    end

    test "reached" do
      with_mocks([
        {ChannelsAuthorization, [],
         [
           authorize_conn: fn _, _, _ ->
             {:ok, %{"exp" => Joken.current_time() + 1_000, "role" => "postgres"}}
           end
         ]}
      ]) do
        {:ok, %Socket{} = socket} = connect(UserSocket, %{}, @default_conn_opts)

        socket_at_capacity =
          Socket.assign(socket, %{limits: %{@default_limits | max_concurrent_users: 0}})

        socket_over_capacity =
          Socket.assign(socket, %{limits: %{@default_limits | max_concurrent_users: -1}})

        assert {:error, %{reason: "Too many connected users"}} =
                 subscribe_and_join(socket_at_capacity, "realtime:test", %{})

        assert {:error, %{reason: "Too many connected users"}} =
                 subscribe_and_join(socket_over_capacity, "realtime:test", %{})
      end
    end
  end

  describe "token expiration" do
    test "valid" do
      with_mocks([
        {ChannelsAuthorization, [],
         [
           authorize_conn: fn _, _, _ ->
             {:ok, %{"exp" => Joken.current_time() + 1, "role" => "postgres"}}
           end
         ]}
      ]) do
        {:ok, %Socket{} = socket} = connect(UserSocket, %{}, @default_conn_opts)

        assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
      end
    end

    test "invalid" do
      with_mocks([
        {ChannelsAuthorization, [],
         [
           authorize_conn: fn _, _, _ ->
             {:ok, %{"exp" => Joken.current_time(), "role" => "postgres"}}
           end
         ]}
      ]) do
        {:ok, %Socket{} = socket} = connect(UserSocket, %{}, @default_conn_opts)

        assert {:error, %{reason: "Token expiration time is invalid"}} =
                 subscribe_and_join(socket, "realtime:test", %{})
      end

      with_mocks([
        {ChannelsAuthorization, [],
         [
           authorize_conn: fn _, _, _ ->
             {:ok, %{"exp" => Joken.current_time() - 1, "role" => "postgres"}}
           end
         ]}
      ]) do
        {:ok, %Socket{} = socket} = connect(UserSocket, %{}, @default_conn_opts)

        assert {:error, %{reason: "Token expiration time is invalid"}} =
                 subscribe_and_join(socket, "realtime:test", %{})
      end
    end
  end

  describe "checks tenant db connectivity" do
    setup_with_mocks([
      {ChannelsAuthorization, [],
       authorize_conn: fn _, _, _ ->
         {:ok, %{"exp" => Joken.current_time() + 1_000, "role" => "postgres"}}
       end}
    ]) do
      :ok
    end

    test "successful connection proceeds with join" do
      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, @default_conn_opts)
      assert {:ok, _, %Socket{}} = subscribe_and_join(socket, "realtime:test", %{})
    end

    test "unsuccessful connection halts join" do
      extensions = [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
            "db_name" => "false",
            "db_user" => "false",
            "db_password" => "false",
            "db_port" => "5433",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1",
            "ssl_enforced" => false
          }
        }
      ]

      tenant = tenant_fixture(%{"extensions" => extensions})

      conn_opts = [
        connect_info: %{
          uri: %{host: "#{tenant.external_id}.localhost:4000/socket/websocket", query: ""},
          x_headers: [{"x-api-key", "token123"}]
        }
      ]

      {:ok, %Socket{} = socket} = connect(UserSocket, %{}, conn_opts)

      assert {:error, %{reason: "Realtime was unable to connect to the project database"}} =
               subscribe_and_join(socket, "realtime:test", %{})
    end
  end
end
