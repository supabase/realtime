Code.require_file("../support/websocket_client.exs", __DIR__)

defmodule Realtime.Integration.RtChannelTest do
  # async: false due to the fact that multiple operations against the database will use the same connection
  use RealtimeWeb.ConnCase, async: false
  import ExUnit.CaptureLog

  require Logger

  alias Ecto.Adapters.SQL.Sandbox
  alias Extensions.PostgresCdcRls, as: Rls
  alias Phoenix.Socket.{V1, Message}
  alias Postgrex, as: P

  alias __MODULE__.Endpoint

  alias Realtime.Api.Tenant
  alias Realtime.Integration.WebsocketClient
  alias Realtime.Repo
  alias Realtime.Tenants.Connect

  @moduletag :capture_log
  @port 4002
  @serializer V1.JSONSerializer
  @external_id "dev_tenant"
  @uri "ws://#{@external_id}.localhost:#{@port}/socket/websocket?vsn=1.0.0"
  @secret "secure_jwt_secret"

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

  setup_all do
    Sandbox.mode(Realtime.Repo, {:shared, self()})
    capture_log(fn -> start_supervised!(Endpoint) end)
    start_supervised!({Phoenix.PubSub, name: __MODULE__})
    :ok
  end

  test "postgres" do
    {socket, _} = get_connection()
    topic = "realtime:any"
    config = %{postgres_changes: [%{event: "*", schema: "public"}]}

    WebsocketClient.join(socket, topic, %{config: config})
    sub_id = :erlang.phash2(%{"event" => "*", "schema" => "public"})

    assert_receive %Message{
                     event: "phx_reply",
                     payload: %{
                       "response" => %{
                         "postgres_changes" => [
                           %{"event" => "*", "id" => ^sub_id, "schema" => "public"}
                         ]
                       },
                       "status" => "ok"
                     },
                     ref: "1",
                     topic: ^topic
                   },
                   10_000

    # skip the presence_state event
    assert_receive %Message{}

    assert_receive %Message{
                     event: "system",
                     payload: %{
                       "channel" => "any",
                       "extension" => "postgres_changes",
                       "message" => "Subscribed to PostgreSQL",
                       "status" => "ok"
                     },
                     ref: nil,
                     topic: ^topic
                   },
                   5000

    {:ok, _, conn} = Rls.get_manager_conn(@external_id)
    P.query!(conn, "insert into test (details) values ('test')", [])

    assert_receive %Message{
                     event: "postgres_changes",
                     payload: %{
                       "data" => %{
                         "columns" => [
                           %{"name" => "id", "type" => "int4"},
                           %{"name" => "details", "type" => "text"}
                         ],
                         "commit_timestamp" => _ts,
                         "errors" => nil,
                         "record" => %{"details" => "test", "id" => id},
                         "schema" => "public",
                         "table" => "test",
                         "type" => "INSERT"
                       },
                       "ids" => [^sub_id]
                     },
                     ref: nil,
                     topic: "realtime:any"
                   },
                   2000

    P.query!(conn, "update test set details = 'test' where id = #{id}", [])

    assert_receive %Message{
                     event: "postgres_changes",
                     payload: %{
                       "data" => %{
                         "columns" => [
                           %{"name" => "id", "type" => "int4"},
                           %{"name" => "details", "type" => "text"}
                         ],
                         "commit_timestamp" => _ts,
                         "errors" => nil,
                         "old_record" => %{"id" => ^id},
                         "record" => %{"details" => "test", "id" => ^id},
                         "schema" => "public",
                         "table" => "test",
                         "type" => "UPDATE"
                       },
                       "ids" => [^sub_id]
                     },
                     ref: nil,
                     topic: "realtime:any"
                   },
                   2000

    P.query!(conn, "delete from test where id = #{id}", [])

    assert_receive %Message{
                     event: "postgres_changes",
                     payload: %{
                       "data" => %{
                         "columns" => [
                           %{"name" => "id", "type" => "int4"},
                           %{"name" => "details", "type" => "text"}
                         ],
                         "commit_timestamp" => _ts,
                         "errors" => nil,
                         "old_record" => %{"id" => ^id},
                         "schema" => "public",
                         "table" => "test",
                         "type" => "DELETE"
                       },
                       "ids" => [^sub_id]
                     },
                     ref: nil,
                     topic: "realtime:any"
                   },
                   2000
  end

  describe "broadcast feature" do
    setup [:rls_context]

    test "public broadcast" do
      {socket, _} = get_connection()

      config = %{
        broadcast: %{self: true}
      }

      topic = "realtime:any"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{
        event: "phx_reply",
        payload: %{
          "response" => %{
            "postgres_changes" => []
          },
          "status" => "ok"
        },
        ref: "1",
        topic: ^topic
      }

      assert_receive %Message{}

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, topic, "broadcast", payload)

      assert_receive %Message{
        event: "broadcast",
        payload: ^payload,
        ref: nil,
        topic: ^topic
      }
    end

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "private broadcast with valid channel with permissions sends message", %{
      topic: topic
    } do
      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}}
      topic = "realtime:#{topic}"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{
        event: "phx_reply",
        payload: %{
          "response" => %{"postgres_changes" => []},
          "status" => "ok"
        },
        ref: "1",
        topic: ^topic
      }

      assert_receive %Message{}

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, topic, "broadcast", payload)

      assert_receive %Message{
        event: "broadcast",
        payload: ^payload,
        ref: nil,
        topic: ^topic
      }
    end

    @tag policies: [:authenticated_read_broadcast_and_presence]
    test "private broadcast with valid channel no write permissions won't send message but will receive message",
         %{topic: topic} do
      {service_role_socket, _} = get_connection("service_role")
      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: true}
      topic = "realtime:#{topic}"
      WebsocketClient.join(service_role_socket, topic, %{config: config})
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{
        event: "phx_reply",
        payload: %{
          "response" => %{"postgres_changes" => []},
          "status" => "ok"
        },
        ref: "1",
        topic: ^topic
      }

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, topic, "broadcast", payload)

      refute_receive %Message{
                       event: "broadcast",
                       payload: ^payload,
                       ref: nil,
                       topic: ^topic
                     },
                     500

      :timer.sleep(1000)
      WebsocketClient.send_event(service_role_socket, topic, "broadcast", payload)

      assert_receive %Message{
                       event: "broadcast",
                       payload: ^payload,
                       ref: nil,
                       topic: ^topic
                     },
                     500

      assert_receive %Message{
                       event: "broadcast",
                       payload: ^payload,
                       ref: nil,
                       topic: ^topic
                     },
                     500
    end
  end

  describe "presence feature" do
    setup [:rls_context]

    test "public presence" do
      {socket, _} = get_connection()
      config = %{presence: %{key: ""}}
      topic = "realtime:any"

      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{
        event: "phx_reply",
        payload: %{
          "response" => %{"postgres_changes" => []},
          "status" => "ok"
        },
        ref: "1",
        topic: ^topic
      }

      assert_receive %Message{
        event: "presence_state",
        payload: %{},
        ref: nil,
        topic: ^topic
      }

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_96", t: 1814.7000000029802}
      }

      WebsocketClient.send_event(socket, topic, "presence", payload)

      assert_receive %Message{
        event: "presence_diff",
        payload: %{"joins" => joins, "leaves" => %{}},
        ref: nil,
        topic: ^topic
      }

      join_payload = joins |> Map.values() |> hd() |> get_in(["metas"]) |> hd()
      assert get_in(join_payload, ["name"]) == payload.payload.name
      assert get_in(join_payload, ["t"]) == payload.payload.t
    end

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "private presence with read and write permissions will be able to track and receive presence changes",
         %{topic: topic} do
      {socket, _} = get_connection("authenticated")
      config = %{presence: %{key: ""}}
      topic = "realtime:#{topic}"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{
                       event: "presence_state",
                       payload: %{},
                       ref: nil,
                       topic: ^topic
                     },
                     500

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_96", t: 1814.7000000029802}
      }

      WebsocketClient.send_event(socket, topic, "presence", payload)

      assert_receive %Message{
                       event: "presence_diff",
                       payload: %{"joins" => joins, "leaves" => %{}},
                       ref: nil,
                       topic: ^topic
                     },
                     500

      join_payload = joins |> Map.values() |> hd() |> get_in(["metas"]) |> hd()
      assert get_in(join_payload, ["name"]) == payload.payload.name
      assert get_in(join_payload, ["t"]) == payload.payload.t
    end

    @tag policies: [:authenticated_read_broadcast_and_presence]
    test "private presence with read permissions will be able to receive presence changes but won't be able to track",
         %{topic: topic} do
      {socket, _} = get_connection("authenticated")
      {secondary_socket, _} = get_connection("service_role")
      config = fn key -> %{presence: %{key: key}, private: true} end
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: config.("authenticated")})

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_96", t: 1814.7000000029802}
      }

      # This will be ignored
      WebsocketClient.send_event(socket, topic, "presence", payload)

      assert_receive %Phoenix.Socket.Message{
        topic: ^topic,
        event: "phx_reply",
        payload: %{"response" => %{"postgres_changes" => []}, "status" => "ok"},
        ref: "1",
        join_ref: nil
      }

      refute_receive %Message{event: "presence_state", payload: _, ref: nil, topic: ^topic}
      refute_receive %Message{event: "presence_diff", payload: _, ref: _, topic: ^topic}

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_97", t: 1814.7000000029802}
      }

      # This will be tracked
      WebsocketClient.join(secondary_socket, topic, %{config: config.("service_role")})
      WebsocketClient.send_event(secondary_socket, topic, "presence", payload)

      assert_receive %Message{
        topic: ^topic,
        event: "presence_diff",
        payload: %{"joins" => joins, "leaves" => %{}},
        ref: nil
      }

      join_payload = joins |> Map.values() |> hd() |> get_in(["metas"]) |> hd()
      assert get_in(join_payload, ["name"]) == payload.payload.name
      assert get_in(join_payload, ["t"]) == payload.payload.t

      assert_receive %Phoenix.Socket.Message{
                       topic: ^topic,
                       event: "presence_diff",
                       ref: nil,
                       join_ref: nil
                     } = res

      assert join_payload =
               res
               |> Map.from_struct()
               |> get_in([:payload, "joins", "service_role", "metas"])
               |> hd()

      assert get_in(join_payload, ["name"]) == payload.payload.name
      assert get_in(join_payload, ["t"]) == payload.payload.t
    end
  end

  test "token required the role key" do
    {:ok, token} = token_no_role()

    assert {:error, %{status_code: 403}} =
             WebsocketClient.connect(self(), @uri, @serializer, [{"x-api-key", token}])
  end

  describe "refresh token" do
    setup [:rls_context]

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "on new access_token and channel is private policies are reevaluated",
         %{topic: topic} do
      {socket, access_token} = get_connection("authenticated")
      {:ok, new_token} = token_valid("anon")

      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{
        config: %{broadcast: %{self: true}, private: true},
        access_token: new_token
      })

      WebsocketClient.send_event(socket, topic, "access_token", %{"access_token" => access_token})

      assert_receive %Phoenix.Socket.Message{
                       event: "phx_reply",
                       payload: %{
                         "response" => %{
                           "reason" => "You do not have permissions to read from this Topic"
                         },
                         "status" => "error"
                       },
                       topic: ^topic
                     },
                     500
    end
  end

  defp token_valid(role), do: generate_token(%{role: role})
  defp token_no_role(), do: generate_token()

  defp generate_token(claims \\ %{}) do
    claims =
      %{
        ref: "localhost",
        iat: System.system_time(:second),
        exp: System.system_time(:second) + 604_800
      }
      |> Map.merge(claims)

    signer = Joken.Signer.create("HS256", @secret)
    Joken.Signer.sign(claims, signer)
  end

  defp get_connection(role \\ "anon") do
    {:ok, token} = token_valid(role)
    {:ok, socket} = WebsocketClient.connect(self(), @uri, @serializer, [{"x-api-key", token}])
    {socket, token}
  end

  def rls_context(context) do
    [tenant] = Repo.all(Tenant)

    {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)

    clean_table(db_conn, "realtime", "messages")
    message = message_fixture(tenant)

    if policies = context[:policies] do
      create_rls_policies(db_conn, policies, message)
    end

    on_exit(fn -> Process.exit(db_conn, :normal) end)

    %{topic: message.topic}
  end
end
