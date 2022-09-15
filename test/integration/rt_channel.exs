Code.require_file("../support/websocket_client.exs", __DIR__)

defmodule Phoenix.Integration.RtChannelTest do
  use RealtimeWeb.ConnCase
  import ExUnit.CaptureLog
  alias Postgrex, as: P

  alias Phoenix.Integration.WebsocketClient
  alias Phoenix.Socket.{V1, Message}
  alias __MODULE__.Endpoint
  alias Extensions.Postgres

  @moduletag :capture_log
  @port 5807
  @serializer V1.JSONSerializer
  @external_id "dev_tenant"
  @token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxvY2FsaG9zdCIsInJvbGUiOiJhdXRoZW50aWNhdGVkIiwiaWF0IjoxNjU4NjAwNzkxLCJleHAiOjE5NzQxNzY3OTF9.asQn-i7DDicPbMN_cjr7QB01kUs1RxFy0CboLmMwZxg"
  @uri "ws://#{@external_id}.localhost:#{@port}/socket/websocket?apikey=#{@token}&vsndate=2022&vsn=1.0.0"

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

    socket("/socket", RealtimeWeb.UserSocket,
      websocket: [
        connect_info: [:peer_data, :uri, :x_headers],
        fullsweep_after: 20,
        max_frame_size: 8_000_000
      ],
      longpoll: false
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

  setup_all do
    Ecto.Adapters.SQL.Sandbox.mode(Realtime.Repo, {:shared, self()})
    capture_log(fn -> start_supervised!(Endpoint) end)
    start_supervised!({Phoenix.PubSub, name: __MODULE__})
    :ok
  end

  test "connection" do
    socket = get_connection()

    config = %{
      postgres_changes: [%{event: "*", schema: "public"}]
    }

    WebsocketClient.join(socket, "realtime:any", %{config: config})
    id = :erlang.phash2(%{"event" => "*", "schema" => "public"})

    assert_receive %Message{
      event: "phx_reply",
      payload: %{
        "response" => %{
          "postgres_changes" => [%{"event" => "*", "id" => ^id, "schema" => "public"}]
        },
        "status" => "ok"
      },
      join_ref: nil,
      ref: "1",
      topic: "realtime:any"
    }

    assert_receive %Message{}

    :timer.sleep(6000)

    assert_receive %Message{
      event: "system",
      join_ref: nil,
      payload: %{
        "message" => "subscribed to realtime",
        "status" => "ok",
        "topic" => "dev_tenant:any"
      },
      ref: nil,
      topic: "realtime:any"
    }
  end

  test "broadcast" do
    socket = get_connection()

    config = %{
      broadcast: %{self: true}
    }

    WebsocketClient.join(socket, "realtime:any", %{config: config})

    assert_receive %Message{
      event: "phx_reply",
      payload: %{
        "response" => %{
          "postgres_changes" => []
        },
        "status" => "ok"
      },
      join_ref: nil,
      ref: "1",
      topic: "realtime:any"
    }

    assert_receive %Message{}

    payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
    WebsocketClient.send_event(socket, "realtime:any", "broadcast", payload)

    assert_receive %Message{
      event: "broadcast",
      join_ref: nil,
      payload: ^payload,
      ref: nil,
      topic: "realtime:any"
    }
  end

  test "presence" do
    socket = get_connection()

    config = %{
      presence: %{key: ""}
    }

    WebsocketClient.join(socket, "realtime:any", %{config: config})

    assert_receive %Message{
      event: "phx_reply",
      payload: %{
        "response" => %{
          "postgres_changes" => []
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

  defp get_connection() do
    {:ok, socket} = WebsocketClient.connect(self(), @uri, @serializer)
    socket
  end
end
