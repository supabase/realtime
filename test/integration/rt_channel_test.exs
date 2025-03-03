Code.require_file("../support/websocket_client.exs", __DIR__)

defmodule Realtime.Integration.RtChannelTest do
  # async: false due to the fact that multiple operations against the same tenant and usage of mocks
  use RealtimeWeb.ConnCase, async: false
  import ExUnit.CaptureLog
  import Generators
  import Mock

  require Logger

  alias Extensions.PostgresCdcRls
  alias Phoenix.Socket.Message
  alias Phoenix.Socket.V1
  alias Postgrex
  alias Realtime.Database
  alias Realtime.Integration.RtChannelTest.Endpoint
  alias Realtime.Integration.WebsocketClient
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Cache

  @moduletag :capture_log
  @port 4002
  @serializer V1.JSONSerializer
  @external_id "dev_tenant"
  @uri "ws://#{@external_id}.localhost:#{@port}/socket/websocket"
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

  setup do
    RateCounter.stop(@external_id)
    Cache.invalidate_tenant_cache(@external_id)
    Process.sleep(500)

    tenant = Tenants.get_tenant_by_external_id(@external_id)

    %{tenant: tenant}
  end

  setup_all do
    capture_log(fn -> start_supervised!(Endpoint) end)
    start_supervised!({Phoenix.PubSub, name: __MODULE__})
    :ok
  end

  test "handle postgres extension" do
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
                   200

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
                   8000

    {:ok, _, conn} = PostgresCdcRls.get_manager_conn(@external_id)
    Postgrex.query!(conn, "insert into test (details) values ('test')", [])

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
                   500

    Postgrex.query!(conn, "update test set details = 'test' where id = #{id}", [])

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
                   500

    Postgrex.query!(conn, "delete from test where id = #{id}", [])

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
                   500
  end

  describe "handle broadcast extension" do
    setup [:rls_context]

    test "public broadcast" do
      {socket, _} = get_connection()

      config = %{
        broadcast: %{self: true},
        private: false
      }

      topic = "realtime:any"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", topic: ^topic}, 500
      assert_receive %Message{}

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, topic, "broadcast", payload)

      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic}, 500
    end

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "private broadcast with valid channel with permissions sends message", %{
      topic: topic
    } do
      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: true}
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
                     },
                     500

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
         ],
         topic: "topic"
    test "private broadcast with valid channel a colon character sends message and won't intercept in public channels",
         %{topic: topic} do
      {anon_socket, _} = get_connection("anon")
      {socket, _} = get_connection("authenticated")
      valid_topic = "realtime:#{topic}"
      malicious_topic = "realtime:private:#{topic}"

      WebsocketClient.join(socket, valid_topic, %{
        config: %{broadcast: %{self: true}, private: true}
      })

      assert_receive %Message{event: "phx_reply", topic: ^valid_topic}, 500
      assert_receive %Message{}, 500

      WebsocketClient.join(anon_socket, malicious_topic, %{
        config: %{broadcast: %{self: true}, private: false}
      })

      assert_receive %Message{event: "phx_reply", topic: ^malicious_topic}, 500
      assert_receive %Message{}, 500

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, valid_topic, "broadcast", payload)

      assert_receive %Message{
                       event: "broadcast",
                       payload: ^payload,
                       topic: ^valid_topic
                     },
                     500

      refute_receive %Message{event: "broadcast"}
    end

    @tag policies: [:authenticated_read_broadcast_and_presence]
    test "private broadcast with valid channel no write permissions won't send message but will receive message",
         %{topic: topic} do
      config = %{broadcast: %{self: true}, private: true}
      topic = "realtime:#{topic}"

      {service_role_socket, _} = get_connection("service_role")

      WebsocketClient.join(service_role_socket, topic, %{config: config})
      assert_receive %Message{event: "phx_reply", topic: ^topic}, 500
      assert_receive %Message{event: "presence_state"}, 500

      {socket, _} = get_connection("authenticated")
      WebsocketClient.join(socket, topic, %{config: config})
      assert_receive %Message{event: "phx_reply", topic: ^topic}, 500
      assert_receive %Message{event: "presence_state"}, 500

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, topic, "broadcast", payload)

      refute_receive %Message{
                       event: "broadcast",
                       payload: ^payload,
                       topic: ^topic
                     },
                     500

      WebsocketClient.send_event(service_role_socket, topic, "broadcast", payload)

      assert_receive %Message{
                       event: "broadcast",
                       payload: ^payload,
                       topic: ^topic
                     },
                     500

      assert_receive %Message{
                       event: "broadcast",
                       payload: ^payload,
                       topic: ^topic
                     },
                     500
    end

    @tag policies: []
    test "private broadcast with valid channel and no read permissions won't join",
         %{topic: topic} do
      config = %{private: true}

      expected = "You do not have permissions to read from this Channel topic: #{topic}"

      topic = "realtime:#{topic}"
      {socket, _} = get_connection("authenticated")

      log =
        capture_log(fn ->
          WebsocketClient.join(socket, topic, %{config: config})

          assert_receive %Message{
                           topic: ^topic,
                           event: "phx_reply",
                           payload: %{"response" => %{"reason" => reason}, "status" => "error"}
                         },
                         1000

          assert reason == expected
          refute_receive %Message{event: "phx_reply", topic: ^topic}, 1000
          refute_receive %Message{event: "presence_state"}, 1000
        end)

      assert log =~ "Unauthorized: #{expected}"
    end
  end

  describe "handle presence extension" do
    setup [:rls_context]

    test "public presence" do
      {socket, _} = get_connection()
      config = %{presence: %{key: ""}, private: false}
      topic = "realtime:any"

      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 500
      assert_receive %Message{event: "presence_state", payload: %{}, topic: ^topic}, 500

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_96", t: 1814.7000000029802}
      }

      WebsocketClient.send_event(socket, topic, "presence", payload)

      assert_receive %Phoenix.Socket.Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}
      assert_receive %Message{event: "presence_diff", payload: %{"joins" => joins, "leaves" => %{}}, topic: ^topic}

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
      config = %{presence: %{key: ""}, private: true}
      topic = "realtime:#{topic}"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "presence_state", payload: %{}, topic: ^topic}, 500

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_96", t: 1814.7000000029802}
      }

      WebsocketClient.send_event(socket, topic, "presence", payload)
      refute_receive %Message{event: "phx_leave", topic: ^topic}
      assert_receive %Message{event: "presence_diff", payload: %{"joins" => joins, "leaves" => %{}}, topic: ^topic}, 500
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

      assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state", payload: %{}, ref: nil, topic: ^topic}
      refute_receive %Message{event: "presence_diff", payload: _, ref: _, topic: ^topic}

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_97", t: 1814.7000000029802}
      }

      # This will be tracked
      WebsocketClient.join(secondary_socket, topic, %{config: config.("service_role")})
      WebsocketClient.send_event(secondary_socket, topic, "presence", payload)

      assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{topic: ^topic, event: "presence_diff", payload: %{"joins" => joins, "leaves" => %{}}}
      assert_receive %Message{event: "presence_state", payload: %{}, ref: nil, topic: ^topic}

      join_payload = joins |> Map.values() |> hd() |> get_in(["metas"]) |> hd()
      assert get_in(join_payload, ["name"]) == payload.payload.name
      assert get_in(join_payload, ["t"]) == payload.payload.t

      assert_receive %Message{topic: ^topic, event: "presence_diff"} = res

      assert join_payload =
               res
               |> Map.from_struct()
               |> get_in([:payload, "joins", "service_role", "metas"])
               |> hd()

      assert get_in(join_payload, ["name"]) == payload.payload.name
      assert get_in(join_payload, ["t"]) == payload.payload.t
    end
  end

  describe "token handling" do
    setup [:rls_context]

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "invalid JWT with expired token" do
      assert capture_log(fn ->
               get_connection("authenticated", %{:exp => System.system_time(:second) - 1000})
             end) =~ "InvalidJWTToken: Token has expired 1000 seconds ago"
    end

    test "token required the role key" do
      {:ok, token} = token_no_role()

      assert {:error, %{status_code: 403}} =
               WebsocketClient.connect(self(), @uri, @serializer, [{"x-api-key", token}])
    end

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "on new access_token and channel is private policies are reevaluated for read policy",
         %{topic: topic} do
      {socket, access_token} = get_connection("authenticated")

      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{
        config: %{broadcast: %{self: true}, private: true},
        access_token: access_token
      })

      assert_receive %Message{event: "phx_reply"}, 500
      assert_receive %Message{event: "presence_state"}, 500

      {:ok, new_token} = token_valid("anon")

      WebsocketClient.send_event(socket, realtime_topic, "access_token", %{
        "access_token" => new_token
      })

      error_message =
        "You do not have permissions to read from this Channel topic: #{topic}"

      assert_receive %Message{
        event: "system",
        payload: %{
          "channel" => ^topic,
          "extension" => "system",
          "message" => ^error_message,
          "status" => "error"
        },
        topic: ^realtime_topic
      }

      assert_receive %Message{event: "phx_close", topic: ^realtime_topic}
    end

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "on new access_token and channel is private policies are reevaluated for write policy",
         %{topic: topic, tenant: tenant} do
      {socket, access_token} = get_connection("authenticated")
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{
        config: %{broadcast: %{self: true}, private: true},
        access_token: access_token
      })

      assert_receive %Message{event: "phx_reply"}, 500
      assert_receive %Message{event: "presence_state"}, 500
      # Checks first send which will set write policy to true
      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, realtime_topic, "broadcast", payload)
      Process.sleep(1000)

      assert_receive %Message{
                       event: "broadcast",
                       payload: ^payload,
                       topic: ^realtime_topic
                     },
                     500

      # RLS policies changed to only allow read
      {:ok, db_conn} = Database.connect(tenant, "realtime_test")
      clean_table(db_conn, "realtime", "messages")
      create_rls_policies(db_conn, [:authenticated_read_broadcast_and_presence], %{topic: topic})

      # Set new token to recheck policies
      {:ok, new_token} =
        generate_token(%{
          exp: System.system_time(:second) + 1000,
          role: "authenticated",
          sub: random_string()
        })

      WebsocketClient.send_event(socket, realtime_topic, "access_token", %{
        "access_token" => new_token
      })

      # Send message to be ignored
      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, realtime_topic, "broadcast", payload)

      Process.sleep(1000)

      refute_receive %Message{
                       event: "broadcast",
                       payload: ^payload,
                       topic: ^realtime_topic
                     },
                     500
    end

    test "on new access_token and channel is public policies are not reevaluated",
         %{topic: topic} do
      {socket, access_token} = get_connection("authenticated")
      {:ok, new_token} = token_valid("anon")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply"}, 500
      assert_receive %Message{event: "presence_state"}, 500

      WebsocketClient.send_event(socket, realtime_topic, "access_token", %{
        "access_token" => new_token
      })

      refute_receive %Message{}
    end

    test "on empty string access_token the socket sends an error message",
         %{topic: topic} do
      {socket, access_token} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply"}, 500
      assert_receive %Message{event: "presence_state"}, 500

      WebsocketClient.send_event(socket, realtime_topic, "access_token", %{"access_token" => ""})

      assert_receive %Message{
        topic: ^realtime_topic,
        event: "system",
        payload: %{
          "extension" => "system",
          "message" => "Token claims must be a map",
          "status" => "error"
        }
      }
    end

    test "on expired access_token the socket sends an error message",
         %{topic: topic} do
      sub = random_string()

      {socket, access_token} =
        get_connection("authenticated", %{sub: sub})

      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply"}, 500
      assert_receive %Message{event: "presence_state"}, 500
      {:ok, token} = generate_token(%{:exp => System.system_time(:second) - 1000, sub: sub})

      log =
        capture_log(fn ->
          WebsocketClient.send_event(socket, realtime_topic, "access_token", %{
            "access_token" => token
          })

          assert_receive %Message{
            topic: ^realtime_topic,
            event: "system",
            payload: %{
              "extension" => "system",
              "message" => "Token has expired 1000 seconds ago",
              "status" => "error"
            }
          }
        end)

      assert log =~ "ChannelShutdown: Token has expired 1000 seconds ago"
    end

    test "ChannelShutdown include sub if available in jwt claims",
         %{topic: topic} do
      sub = random_string()

      {socket, access_token} =
        get_connection("authenticated", %{sub: sub}, %{log_level: :warning})

      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})
      {:ok, token} = generate_token(%{:exp => System.system_time(:second) - 1000, sub: sub})

      log =
        capture_log(fn ->
          WebsocketClient.send_event(socket, realtime_topic, "access_token", %{
            "access_token" => token
          })

          assert_receive %Message{event: "system"}, 500
        end)

      assert log =~ "ChannelShutdown"
      assert log =~ "sub=#{sub}"
    end

    test "missing claims close connection",
         %{topic: topic} do
      {socket, access_token} =
        get_connection("authenticated")

      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply"}, 500
      assert_receive %Message{event: "presence_state"}, 500
      {:ok, token} = generate_token(%{:exp => System.system_time(:second) + 2000})
      # Update token to be a near expiring token
      WebsocketClient.send_event(socket, realtime_topic, "access_token", %{
        "access_token" => token
      })

      assert_receive %Message{
                       event: "system",
                       payload: %{
                         "extension" => "system",
                         "message" => "Fields `role` and `exp` are required in JWT",
                         "status" => "error"
                       }
                     },
                     500

      assert_receive %Message{event: "phx_close"}
    end

    test "checks token periodically",
         %{topic: topic} do
      {socket, access_token} =
        get_connection("authenticated")

      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply"}, 500
      assert_receive %Message{event: "presence_state"}, 500

      {:ok, token} =
        generate_token(%{:exp => System.system_time(:second) + 2, role: "authenticated"})

      # Update token to be a near expiring token
      WebsocketClient.send_event(socket, realtime_topic, "access_token", %{
        "access_token" => token
      })

      # Awaits to see if connection closes automatically
      assert_receive %Message{
                       event: "system",
                       payload: %{
                         "extension" => "system",
                         "message" => msg,
                         "status" => "error"
                       }
                     },
                     3000

      assert_receive %Message{event: "phx_close"}

      assert msg =~ "Token has expired"
    end

    test "token expires in between joins", %{topic: topic} do
      {socket, access_token} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply"}, 500
      assert_receive %Message{event: "presence_state"}, 500

      {:ok, access_token} =
        generate_token(%{:exp => System.system_time(:second) + 1, role: "authenticated"})

      # token expires in between joins so it needs to be handled by the channel and not the socket
      Process.sleep(1000)
      realtime_topic = "realtime:#{topic}"
      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "status" => "error",
                         "response" => %{"reason" => "Token has expired 0 seconds ago"}
                       },
                       topic: ^realtime_topic
                     },
                     500

      assert_receive %Message{event: "phx_close"}
    end

    test "token loses claims in between joins", %{topic: topic} do
      {socket, access_token} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply"}, 500
      assert_receive %Message{event: "presence_state"}, 500

      {:ok, access_token} = generate_token(%{:exp => System.system_time(:second) + 10})

      # token breaks claims in between joins so it needs to be handled by the channel and not the socket
      Process.sleep(1000)
      realtime_topic = "realtime:#{topic}"
      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "status" => "error",
                         "response" => %{
                           "reason" => "Fields `role` and `exp` are required in JWT"
                         }
                       },
                       topic: ^realtime_topic
                     },
                     500

      assert_receive %Message{event: "phx_close"}
    end

    test "token is badly formatted in between joins", %{topic: topic} do
      {socket, access_token} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply"}, 500
      assert_receive %Message{event: "presence_state"}, 500

      # token becomes a string in between joins so it needs to be handled by the channel and not the socket
      Process.sleep(1000)
      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: "potato"})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "status" => "error",
                         "response" => %{"reason" => "Token claims must be a map"}
                       },
                       topic: ^realtime_topic
                     },
                     500

      assert_receive %Message{event: "phx_close"}
    end

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "handles RPC error on token refreshed", %{topic: topic} do
      with_mocks [
        {Authorization, [:passthrough], build_authorization_params: &passthrough([&1])},
        {Authorization, [:passthrough],
         get_read_authorizations: [
           in_series([:_, :_, :_], [&passthrough([&1, &2, &3]), {:error, "RPC Error"}])
         ]}
      ] do
        {socket, access_token} = get_connection("authenticated")
        config = %{broadcast: %{self: true}, private: true}
        realtime_topic = "realtime:#{topic}"

        WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

        assert_receive %Phoenix.Socket.Message{event: "phx_reply"}, 500
        assert_receive %Phoenix.Socket.Message{event: "presence_state"}, 500

        # Update token to force update
        {:ok, access_token} =
          generate_token(%{:exp => System.system_time(:second) + 1000, role: "authenticated"})

        log =
          capture_log(fn ->
            WebsocketClient.send_event(socket, realtime_topic, "access_token", %{
              "access_token" => access_token
            })

            assert_receive %Phoenix.Socket.Message{
                             event: "system",
                             payload: %{
                               "status" => "error",
                               "extension" => "system",
                               "message" => "Realtime was unable to connect to the project database"
                             },
                             topic: ^realtime_topic,
                             join_ref: nil,
                             ref: nil
                           },
                           500

            assert_receive %Phoenix.Socket.Message{event: "phx_close", topic: ^realtime_topic}
          end)

        assert log =~ "Realtime was unable to connect to the project database"
      end
    end
  end

  describe "handle broadcast changes" do
    setup [:rls_context, :setup_trigger]

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "broadcast insert event changes on insert in table with trigger", %{
      topic: topic,
      db_conn: db_conn,
      table_name: table_name
    } do
      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: true}
      topic = "realtime:#{topic}"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500
      Process.sleep(500)
      value = random_string()
      Postgrex.query!(db_conn, "INSERT INTO #{table_name} (details) VALUES ($1)", [value])

      record = %{"details" => value, "id" => 1}

      assert_receive %Message{
                       event: "broadcast",
                       payload: %{
                         "event" => "INSERT",
                         "payload" => %{
                           "old_record" => nil,
                           "operation" => "INSERT",
                           "record" => ^record,
                           "schema" => "public",
                           "table" => ^table_name
                         },
                         "type" => "broadcast"
                       },
                       topic: ^topic
                     },
                     200
    end

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ],
         requires_data: true
    test "broadcast update event changes on update in table with trigger", %{
      topic: topic,
      db_conn: db_conn,
      table_name: table_name
    } do
      value = random_string()

      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: true}
      topic = "realtime:#{topic}"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500
      Process.sleep(500)
      new_value = random_string()

      Postgrex.query!(db_conn, "INSERT INTO #{table_name} (details) VALUES ($1)", [value])

      Postgrex.query!(db_conn, "UPDATE #{table_name} SET details = $1 WHERE details = $2", [
        new_value,
        value
      ])

      Process.sleep(500)
      old_record = %{"details" => value, "id" => 1}
      record = %{"details" => new_value, "id" => 1}

      assert_receive %Message{
                       event: "broadcast",
                       payload: %{
                         "event" => "UPDATE",
                         "payload" => %{
                           "old_record" => ^old_record,
                           "operation" => "UPDATE",
                           "record" => ^record,
                           "schema" => "public",
                           "table" => ^table_name
                         },
                         "type" => "broadcast"
                       },
                       topic: ^topic
                     },
                     200
    end

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "broadcast delete event changes on delete in table with trigger", %{
      topic: topic,
      db_conn: db_conn,
      table_name: table_name
    } do
      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: true}
      topic = "realtime:#{topic}"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500
      Process.sleep(500)
      value = random_string()

      Postgrex.query!(db_conn, "INSERT INTO #{table_name} (details) VALUES ($1)", [value])
      Postgrex.query!(db_conn, "DELETE FROM #{table_name} WHERE details = $1", [value])

      record = %{"details" => value, "id" => 1}

      assert_receive %Message{
                       event: "broadcast",
                       payload: %{
                         "event" => "DELETE",
                         "payload" => %{
                           "old_record" => ^record,
                           "operation" => "DELETE",
                           "record" => nil,
                           "schema" => "public",
                           "table" => ^table_name
                         },
                         "type" => "broadcast"
                       },
                       topic: ^topic
                     },
                     200
    end

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "broadcast event when function 'send' is called with private topic", %{
      topic: topic,
      db_conn: db_conn
    } do
      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: true}
      full_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, full_topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500
      Process.sleep(500)
      value = random_string()
      event = random_string()

      Postgrex.query!(
        db_conn,
        "SELECT realtime.send (json_build_object ('value', $1 :: text)::jsonb, $2 :: text, $3 :: text, TRUE::bool);",
        [value, event, topic]
      )

      assert_receive %Message{
                       event: "broadcast",
                       payload: %{
                         "event" => ^event,
                         "payload" => %{"value" => ^value},
                         "type" => "broadcast"
                       },
                       topic: ^full_topic,
                       join_ref: nil,
                       ref: nil
                     },
                     500
    end

    test "broadcast event when function 'send' is called with public topic", %{
      topic: topic,
      db_conn: db_conn
    } do
      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: false}
      full_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, full_topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500
      Process.sleep(500)
      value = random_string()
      event = random_string()

      Postgrex.query!(
        db_conn,
        "SELECT realtime.send (json_build_object ('value', $1 :: text)::jsonb, $2 :: text, $3 :: text, FALSE::bool);",
        [value, event, topic]
      )

      assert_receive %Message{
                       event: "broadcast",
                       payload: %{
                         "event" => ^event,
                         "payload" => %{"value" => ^value},
                         "type" => "broadcast"
                       },
                       topic: ^full_topic
                     },
                     500
    end
  end

  describe "only private channels" do
    setup [:rls_context]

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "user with only private channels enabled will not be able to join public channels", %{
      topic: topic
    } do
      change_tenant_configuration(:private_only, true)

      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: false}
      topic = "realtime:#{topic}"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "response" => %{"reason" => "This project only allows private channels"},
                         "status" => "error"
                       }
                     },
                     500

      change_tenant_configuration(:private_only, false)
    end

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "user with only private channels enabled will be able to join private channels", %{
      topic: topic
    } do
      change_tenant_configuration(:private_only, true)

      Realtime.Tenants.Cache.invalidate_tenant_cache(@external_id)

      Process.sleep(100)

      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: true}
      topic = "realtime:#{topic}"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply"}, 500
      change_tenant_configuration(:private_only, false)
    end
  end

  describe "sensitive information updates" do
    setup [:rls_context]

    test "on jwks the socket closes and sends a system message", %{topic: topic} do
      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})

      assert_receive %Message{event: "phx_reply"}, 500
      assert_receive %Message{event: "presence_state"}, 500
      tenant = Tenants.get_tenant_by_external_id(@external_id)
      Realtime.Api.update_tenant(tenant, %{jwt_jwks: %{keys: ["potato"]}})

      assert_receive %Message{
                       topic: ^realtime_topic,
                       event: "system",
                       payload: %{
                         "extension" => "system",
                         "message" => "Server requested disconnect",
                         "status" => "ok"
                       }
                     },
                     500
    end

    test "on jwt_secret the socket closes and sends a system message", %{topic: topic} do
      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})

      assert_receive %Message{event: "phx_reply"}, 500
      assert_receive %Message{event: "presence_state"}, 500

      tenant = Tenants.get_tenant_by_external_id(@external_id)
      Realtime.Api.update_tenant(tenant, %{jwt_secret: "potato"})

      assert_receive %Message{
                       topic: ^realtime_topic,
                       event: "system",
                       payload: %{
                         "extension" => "system",
                         "message" => "Server requested disconnect",
                         "status" => "ok"
                       }
                     },
                     500
    end

    test "on other param changes the socket won't close and no message is sent", %{topic: topic} do
      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})

      assert_receive %Message{event: "phx_reply"}, 500
      assert_receive %Message{event: "presence_state"}, 500

      tenant = Tenants.get_tenant_by_external_id(@external_id)
      Realtime.Api.update_tenant(tenant, %{max_concurrent_users: 100})

      refute_receive %Message{
                       topic: ^realtime_topic,
                       event: "system",
                       payload: %{
                         "extension" => "system",
                         "message" => "Server requested disconnect",
                         "status" => "ok"
                       }
                     },
                     500
    end

    test "invalid JWT with expired token" do
      log =
        capture_log(fn ->
          get_connection("authenticated", %{:exp => System.system_time(:second) - 1000})
        end)

      assert log =~ "InvalidJWTToken: Token has expired"
    end
  end

  describe "rate limits" do
    setup [:rls_context]

    test "max_concurrent_users limit respected" do
      %{max_concurrent_users: max_concurrent_users} =
        Tenants.get_tenant_by_external_id(@external_id)

      change_tenant_configuration(:max_concurrent_users, 1)

      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{random_string()}"
      WebsocketClient.join(socket, realtime_topic, %{config: config})
      WebsocketClient.join(socket, realtime_topic, %{config: config})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "response" => %{
                           "reason" => "Too many connected users"
                         },
                         "status" => "error"
                       }
                     },
                     500

      assert_receive %Message{event: "phx_close"}

      change_tenant_configuration(:max_concurrent_users, max_concurrent_users)
    end

    test "max_events_per_second limit respected" do
      %{max_events_per_second: max_concurrent_users} =
        Tenants.get_tenant_by_external_id(@external_id)

      change_tenant_configuration(:max_events_per_second, 1)

      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{random_string()}"
      WebsocketClient.join(socket, realtime_topic, %{config: config})

      for _ <- 1..1000 do
        WebsocketClient.send_event(socket, realtime_topic, "broadcast", %{})
        1..5 |> Enum.random() |> Process.sleep()
      end

      assert_receive %Message{
                       event: "system",
                       payload: %{
                         "status" => "error",
                         "extension" => "system",
                         "message" => "Too many messages per second"
                       }
                     },
                     2000

      assert_receive %Message{event: "phx_close"}

      change_tenant_configuration(:max_events_per_second, max_concurrent_users)
    end

    test "max_channels_per_client limit respected" do
      %{max_events_per_second: max_concurrent_users} =
        Tenants.get_tenant_by_external_id(@external_id)

      change_tenant_configuration(:max_channels_per_client, 1)

      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic_1 = "realtime:#{random_string()}"
      realtime_topic_2 = "realtime:#{random_string()}"

      WebsocketClient.join(socket, realtime_topic_1, %{config: config})
      WebsocketClient.join(socket, realtime_topic_2, %{config: config})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{"response" => %{"postgres_changes" => []}, "status" => "ok"},
                       topic: ^realtime_topic_1
                     },
                     500

      assert_receive %Message{event: "presence_state", topic: ^realtime_topic_1},
                     500

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "status" => "error",
                         "response" => %{"reason" => "Too many channels"}
                       },
                       join_ref: nil,
                       topic: ^realtime_topic_2
                     },
                     500

      refute_receive %Message{event: "phx_reply", topic: ^realtime_topic_2},
                     500

      refute_receive %Message{event: "presence_state", topic: ^realtime_topic_2},
                     500

      change_tenant_configuration(:max_channels_per_client, max_concurrent_users)
    end

    test "max_joins_per_second limit respected" do
      %{max_joins_per_second: max_joins_per_second} =
        Tenants.get_tenant_by_external_id(@external_id)

      change_tenant_configuration(:max_joins_per_second, 1)

      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{random_string()}"

      for _ <- 1..1000 do
        WebsocketClient.join(socket, realtime_topic, %{config: config})
        1..5 |> Enum.random() |> Process.sleep()
      end

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "response" => %{
                           "reason" => "Too many joins per second"
                         },
                         "status" => "error"
                       }
                     },
                     2000

      change_tenant_configuration(:max_joins_per_second, max_joins_per_second)
    end
  end

  describe "authorization handling" do
    setup [:rls_context]

    @tag role: "authenticated",
         policies: [:broken_read_presence, :broken_write_presence]
    test "handle failing rls policy" do
      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: true}
      topic = random_string()
      realtime_topic = "realtime:#{topic}"

      log =
        capture_log(fn ->
          WebsocketClient.join(socket, realtime_topic, %{config: config})

          msg = "You do not have permissions to read from this Channel topic: #{topic}"

          assert_receive %Message{
                           event: "phx_reply",
                           payload: %{
                             "response" => %{"reason" => ^msg},
                             "status" => "error"
                           }
                         },
                         500

          refute_receive %Message{event: "phx_reply"}
          refute_receive %Message{event: "presence_state"}
        end)

      assert log =~ "RlsPolicyError"
    end
  end

  test "handle empty topic by closing the socket" do
    {socket, _} = get_connection("authenticated")
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

  defp token_valid(role, claims \\ %{}), do: generate_token(Map.put(claims, :role, role))
  defp token_no_role, do: generate_token()

  defp generate_token(claims \\ %{}) do
    claims =
      Map.merge(
        %{
          ref: "127.0.0.1",
          iat: System.system_time(:second),
          exp: System.system_time(:second) + 604_800
        },
        claims
      )

    {:ok, generate_jwt_token(@secret, claims)}
  end

  defp get_connection(
         role \\ "anon",
         claims \\ %{},
         params \\ %{vsn: "1.0.0", log_level: :warning}
       ) do
    params = Enum.reduce(params, "", fn {k, v}, acc -> "#{acc}&#{k}=#{v}" end)
    uri = "#{@uri}?#{params}"

    with {:ok, token} <- token_valid(role, claims),
         {:ok, socket} <-
           WebsocketClient.connect(self(), uri, @serializer, [{"x-api-key", token}]) do
      {socket, token}
    end
  end

  def rls_context(%{tenant: tenant} = context) do
    {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)

    clean_table(db_conn, "realtime", "messages")
    topic = Map.get(context, :topic, random_string())
    message = message_fixture(tenant, %{topic: topic})

    if policies = context[:policies] do
      create_rls_policies(db_conn, policies, message)
    end

    Map.put(context, :topic, message.topic)
  end

  def setup_trigger(%{tenant: tenant, topic: topic} = context) do
    Realtime.Tenants.Connect.shutdown(@external_id)
    Process.sleep(500)

    {:ok, db_conn} = Realtime.Tenants.Connect.connect(@external_id)

    random_name = String.downcase("test_#{random_string()}")
    query = "CREATE TABLE #{random_name} (id serial primary key, details text)"
    Postgrex.query!(db_conn, query, [])

    query = """
    CREATE OR REPLACE FUNCTION broadcast_changes_for_table_#{random_name}_trigger ()
    RETURNS TRIGGER
    AS $$
    DECLARE
    topic text;
    BEGIN
    topic = '#{topic}';
    PERFORM
      realtime.broadcast_changes (topic, TG_OP, TG_OP, TG_TABLE_NAME, TG_TABLE_SCHEMA, NEW, OLD, TG_LEVEL);
    RETURN NULL;
    END;
    $$
    LANGUAGE plpgsql;
    """

    Postgrex.query!(db_conn, query, [])

    query = """
    CREATE TRIGGER broadcast_changes_for_#{random_name}_table
    AFTER INSERT OR UPDATE OR DELETE ON #{random_name}
    FOR EACH ROW
    EXECUTE FUNCTION broadcast_changes_for_table_#{random_name}_trigger ();
    """

    Postgrex.query!(db_conn, query, [])

    on_exit(fn ->
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
      query = "DROP TABLE #{random_name} CASCADE"
      Postgrex.query!(db_conn, query, [])
      Realtime.Tenants.Connect.shutdown(db_conn)

      Process.sleep(500)
    end)

    context
    |> Map.put(:db_conn, db_conn)
    |> Map.put(:table_name, random_name)
  end

  defp change_tenant_configuration(limit, value) do
    @external_id
    |> Realtime.Tenants.get_tenant_by_external_id()
    |> Realtime.Api.Tenant.changeset(%{limit => value})
    |> Realtime.Repo.update!()

    Realtime.Tenants.Cache.invalidate_tenant_cache(@external_id)
  end
end
