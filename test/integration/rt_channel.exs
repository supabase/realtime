Code.require_file("../support/websocket_client.exs", __DIR__)

defmodule Phoenix.Integration.RtChannelTest do
  use RealtimeWeb.ConnCase
  import ExUnit.CaptureLog

  alias Phoenix.Integration.WebsocketClient
  alias Phoenix.Socket.{V1, V2, Message}
  alias __MODULE__.Endpoint

  @moduletag :capture_log
  @port 5807
  @serializer V1.JSONSerializer
  @external_id "dev_tenant"
  @token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJvbGUiOiJhbm9uIiwiaWF0IjoxNjQ5OTYzNTc1LCJleHAiOjE5NjU1Mzk1NzV9.v7UZK05KaVQKInBBH_AP5h0jXUEwCCC5qtdj3iaxbNQ"

  Application.put_env(:phoenix, Endpoint,
    https: false,
    http: [port: @port],
    debug_errors: false,
    server: true,
    pubsub_server: __MODULE__,
    secret_key_base: String.duplicate("a", 64)
  )

  Application.put_env(:joken, :current_time_adapter, Joken.CurrentTime.OS)

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :phoenix

    @session_config store: :cookie,
                    key: "_hello_key",
                    signing_salt: "change_me"

    socket "/socket", RealtimeWeb.UserSocket,
      websocket: [
        connect_info: [:peer_data, :uri, :x_headers],
        fullsweep_after: 20,
        max_frame_size: 8_000_000
      ],
      longpoll: false

    plug Plug.Session, @session_config
    plug :fetch_session
    plug Plug.CSRFProtection
    plug :put_session

    defp put_session(conn, _) do
      conn
      |> put_session(:from_session, "123")
      |> send_resp(200, Plug.CSRFProtection.get_csrf_token())
    end
  end

  setup_all do
    Ecto.Adapters.SQL.Sandbox.mode(Realtime.Repo, {:shared, self()})
    capture_log(fn -> start_supervised!(Endpoint) end)
    start_supervised!({Phoenix.PubSub, name: __MODULE__})
    :ok
  end

  @endpoint Endpoint

  describe "connection" do
    test "messages can be pushed and received" do
      {:ok, socket} =
        WebsocketClient.connect(
          self(),
          "ws://#{@external_id}.localhost:#{@port}/socket/websocket?apikey=#{@token}&vsndate=2022&vsn=1.0.0",
          @serializer
        )

      config = %{
        broadcast: %{self: true},
        presence: %{key: ""},
        postgres_changes: [%{event: "*", schema: "public"}]
      }

      WebsocketClient.join(socket, "realtime:any", %{config: config})

      assert_receive %Message{
        event: "phx_reply",
        payload: %{
          "response" => %{
            "postgres_changes" => [%{"event" => "*", "id" => 74_307_548, "schema" => "public"}]
          },
          "status" => "ok"
        },
        join_ref: nil,
        ref: "1",
        topic: "realtime:any"
      }

      assert_receive %Message{
        event: "presence_state",
        join_ref: nil,
        payload: %{},
        ref: nil,
        topic: "realtime:any"
      }

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_96", t: 1814.7000000029802}
      }

      WebsocketClient.send_event(socket, "realtime:any", "presence", payload)

      assert_receive %Message{
        event: "presence_diff",
        join_ref: nil,
        payload:
          %{
            # "joins" => %{
            #   "e0db62a8-34fb-11ed-95f2-fe267df90fe2" => %{
            #     "metas" => [
            #       %{
            #         "name" => "realtime_presence_96",
            #         "phx_ref" => "FxUMVDdHmAbLngMi",
            #         "t" => 1814.7000000029802
            #       }
            #     ]
            #   }
            # },
            # "leaves" => %{}
          },
        ref: nil,
        topic: "realtime:any"
      }
    end
  end
end
