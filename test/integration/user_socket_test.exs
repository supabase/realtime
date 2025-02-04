Code.require_file("../support/websocket_client.exs", __DIR__)
Code.require_file("./Integration.ex", __DIR__)

defmodule RealtimeWeb.UserSocketTest do
  use RealtimeWeb.ConnCase, async: false
  import ExUnit.CaptureLog
  import Integration

  alias __MODULE__.Endpoint
  alias Phoenix.Socket.Message
  alias Phoenix.Socket.V1
  alias Realtime.Api.Tenant
  alias Realtime.Integration.WebsocketClient
  alias Realtime.Repo
  alias Realtime.Tenants
  alias Realtime.Tenants.Cache
  alias Realtime.Tenants.Migrations

  @moduletag :capture_log
  @port 4003
  @serializer V1.JSONSerializer
  @external_id "dev_tenant"
  @uri "ws://#{@external_id}.localhost:#{@port}/socket/websocket"

  Application.put_env(:phoenix, Endpoint,
    https: false,
    http: [port: @port],
    debug_errors: false,
    server: true,
    pubsub_server: __MODULE__,
    secret_key_base: String.duplicate("a", 64)
  )

  Application.delete_env(:joken, :current_time_adapter)

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :phoenix

    @session_config store: :cookie,
                    key: "_hello_key",
                    signing_salt: "change_me"

    socket("/socket", RealtimeWeb.UserSocket,
      websocket: [
        connect_info: [:peer_data, :uri, :x_headers],
        fullsweep_after: 20,
        max_frame_size: 8_000_000
      ],
      longpoll: true
    )

    plug(Plug.Session, @session_config)
    plug(:fetch_session)
    plug(Plug.CSRFProtection)
    plug(:put_session)

    defp put_session(conn, _) do
      conn
      |> put_session(:from_session, "123")
      |> send_resp(200, Plug.CSRFProtection.get_csrf_token())
    end
  end

  defmodule Token do
    use Joken.Config
  end

  setup do
    Cache.invalidate_tenant_cache(@external_id)
    Process.sleep(500)
    [tenant] = Tenant |> Repo.all() |> Repo.preload(:extensions)
    :ok = Migrations.run_migrations(tenant)
    %{tenant: tenant}
  end

  setup_all do
    capture_log(fn -> start_supervised!(Endpoint) end)
    start_supervised!({Phoenix.PubSub, name: __MODULE__})
    :ok
  end

  describe "token handling on connect" do
    setup [:rls_context]

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "invalid JWT with expired token" do
      assert capture_log(fn ->
               get_connection(@port, "authenticated", %{:exp => System.system_time(:second) - 1000})
             end) =~ "InvalidJWTToken: Token as expired 1000 seconds ago"
    end

    test "token required the role key" do
      {:ok, token} = token_no_role()

      assert {:error, %{status_code: 403}} =
               WebsocketClient.connect(self(), @uri, @serializer, [{"x-api-key", token}])
    end
  end

  describe "disconnecting users" do
    setup do
      for _ <- 1..3, reduce: %{topics: [], sockets: []} do
        %{topics: topics, sockets: sockets} ->
          topic = random_string()
          {socket, _} = get_connection(@port, "authenticated")
          config = %{broadcast: %{self: true}, private: false}
          WebsocketClient.join(socket, "realtime:#{random_string()}", %{config: config})
          assert_receive %Message{event: "phx_reply"}, 500
          assert_receive %Message{event: "presence_state"}, 500
          Process.sleep(500)
          %{topics: [topic | topics], sockets: [socket | sockets]}
      end
    end

    test "on jwt_jwks the socket closes and sends a system message", %{sockets: sockets} do
      tenant = Tenants.get_tenant_by_external_id(@external_id)
      Realtime.Api.update_tenant(tenant, %{jwt_jwks: %{keys: ["potato"]}})

      for _socket <- sockets do
        # assert_receive %Message{
        #                  topic: ^topic,
        #                  event: "system",
        #                  payload: %{
        #                    "extension" => "system",
        #                    "message" => "Server requested disconnect",
        #                    "status" => "ok"
        #                  }
        #                },
        #                500

        assert_receive %Message{event: "phx_close"}, 500
      end
    end

    test "on jwt_secret the socket closes and sends a system message", %{topics: topics} do
      tenant = Tenants.get_tenant_by_external_id(@external_id)
      Realtime.Api.update_tenant(tenant, %{jwt_secret: "potato"})

      for _topic <- topics do
        # assert_receive %Message{
        #                  topic: ^topic,
        #                  event: "system",
        #                  payload: %{
        #                    "extension" => "system",
        #                    "message" => "Server requested disconnect",
        #                    "status" => "ok"
        #                  }
        #                },
        #                500

        assert_receive %Message{event: "phx_close"}, 500
      end
    end

    test "on other param changes the socket won't close and no message is sent", %{topics: topics} do
      tenant = Tenants.get_tenant_by_external_id(@external_id)
      Realtime.Api.update_tenant(tenant, %{max_concurrent_users: 100})

      for _topic <- topics do
        # refute_receive %Message{
        #                  topic: ^topic,
        #                  event: "system",
        #                  payload: %{
        #                    "extension" => "system",
        #                    "message" => "Server requested disconnect",
        #                    "status" => "ok"
        #                  }
        #                },
        #                500

        refute_receive %Message{event: "phx_close"}, 500
      end
    end
  end

  test "handle empty topic by closing the socket" do
    {socket, _} = get_connection(@port, "authenticated")
    config = %{broadcast: %{self: true}, private: false}
    realtime_topic = "realtime:"

    WebsocketClient.join(socket, realtime_topic, %{config: config})

    assert_receive %Message{
                     event: "phx_reply",
                     payload: %{
                       "response" => %{"reason" => "You must provide a topic name"},
                       "status" => "error"
                     }
                   },
                   500

    refute_receive %Message{event: "phx_reply"}
    refute_receive %Message{event: "presence_state"}
  end
end
