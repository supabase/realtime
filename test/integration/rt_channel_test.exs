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
  alias Realtime.Database
  alias Realtime.Integration.WebsocketClient
  alias Realtime.Repo
  alias Realtime.Tenants.Migrations

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

  setup do
    [tenant] = Tenant |> Repo.all() |> Repo.preload(:extensions)
    [%{settings: settings} | _] = tenant.extensions
    migrations = %Migrations{tenant_external_id: tenant.external_id, settings: settings}
    :ok = Migrations.run_migrations(migrations)

    %{tenant: tenant}
  end

  setup_all do
    Sandbox.mode(Realtime.Repo, {:shared, self()})
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
                   500

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
                   500

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
                     },
                     500

      assert_receive %Message{}

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, topic, "broadcast", payload)

      assert_receive %Message{
                       event: "broadcast",
                       payload: ^payload,
                       topic: ^topic
                     },
                     500
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
  end

  describe "handle presence extension" do
    setup [:rls_context]

    test "public presence" do
      {socket, _} = get_connection()
      config = %{presence: %{key: ""}, private: false}
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
                     },
                     500

      assert_receive %Message{
                       event: "presence_state",
                       payload: %{},
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
      config = %{presence: %{key: ""}, private: true}
      topic = "realtime:#{topic}"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{
                       event: "presence_state",
                       payload: %{},
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
                     },
                     500

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

  describe "handle refresh token messages" do
    setup [:rls_context]

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "on new access_token and channel is private policies are reevaluated",
         %{topic: topic} do
      {socket, access_token} = get_connection("authenticated")
      {:ok, new_token} = token_valid("anon")

      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{
        config: %{broadcast: %{self: true}, private: true},
        access_token: access_token
      })

      assert_receive %Phoenix.Socket.Message{event: "phx_reply"}, 500
      assert_receive %Phoenix.Socket.Message{event: "presence_state"}, 500

      WebsocketClient.send_event(socket, realtime_topic, "access_token", %{
        "access_token" => new_token
      })

      error_message =
        "Received an invalid access token from client: You do not have permissions to read from this Channel topic: #{topic}"

      assert_receive %Phoenix.Socket.Message{
        event: "system",
        payload: %{
          "channel" => ^topic,
          "extension" => "system",
          "message" => ^error_message,
          "status" => "error"
        },
        topic: ^realtime_topic
      }

      assert_receive %Phoenix.Socket.Message{event: "phx_close", topic: ^realtime_topic}
    end

    test "on new access_token and channel is public policies are not reevaluated",
         %{topic: topic} do
      {socket, access_token} = get_connection("authenticated")
      {:ok, new_token} = token_valid("anon")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Phoenix.Socket.Message{event: "phx_reply"}, 500
      assert_receive %Phoenix.Socket.Message{event: "presence_state"}, 500

      WebsocketClient.send_event(socket, realtime_topic, "access_token", %{
        "access_token" => new_token
      })

      refute_receive %Phoenix.Socket.Message{}
    end
  end

  describe "handle broadcast changes" do
    setup [:rls_context, :setup_trigger]

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ],
         notify_private_alpha: true
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
      :timer.sleep(500)
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
         notify_private_alpha: true,
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
      :timer.sleep(500)
      new_value = random_string()

      Postgrex.query!(db_conn, "INSERT INTO #{table_name} (details) VALUES ($1)", [value])

      Postgrex.query!(db_conn, "UPDATE #{table_name} SET details = $1 WHERE details = $2", [
        new_value,
        value
      ])

      :timer.sleep(500)
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
         ],
         notify_private_alpha: true
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
      :timer.sleep(500)
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
         ],
         notify_private_alpha: true
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
      :timer.sleep(500)
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

    @tag notify_private_alpha: true
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
      :timer.sleep(500)
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
      Realtime.Tenants.update_management(@external_id, %{private_only: true})
      :timer.sleep(100)
      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: false}
      topic = "realtime:#{topic}"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Phoenix.Socket.Message{
                       event: "phx_reply",
                       payload: %{
                         "response" => %{"reason" => "This project only allows private channels"},
                         "status" => "error"
                       }
                     },
                     500

      Realtime.Tenants.update_management(@external_id, %{private_only: false})
      :timer.sleep(100)
    end

    @tag policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "user with only private channels enabled will be able to join private channels", %{
      topic: topic
    } do
      Realtime.Tenants.update_management(@external_id, %{private_only: true})
      :timer.sleep(100)
      {socket, _} = get_connection("authenticated")
      config = %{broadcast: %{self: true}, private: true}
      topic = "realtime:#{topic}"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Phoenix.Socket.Message{event: "phx_reply"}, 500
      Realtime.Tenants.update_management(@external_id, %{private_only: false})
      :timer.sleep(100)
    end
  end

  defp token_valid(role), do: generate_token(%{role: role})
  defp token_no_role(), do: generate_token()

  defp generate_token(claims \\ %{}) do
    claims =
      Map.merge(
        %{
          ref: "localhost",
          iat: System.system_time(:second),
          exp: System.system_time(:second) + 604_800
        },
        claims
      )

    signer = Joken.Signer.create("HS256", @secret)
    Joken.Signer.sign(claims, signer)
  end

  defp get_connection(role \\ "anon") do
    {:ok, token} = token_valid(role)
    {:ok, socket} = WebsocketClient.connect(self(), @uri, @serializer, [{"x-api-key", token}])
    {socket, token}
  end

  def rls_context(%{tenant: tenant} = context) do
    {:ok, db_conn} =
      Database.connect(tenant, "realtime_test", 1)

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
    :timer.sleep(1000)
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
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", 1)
      query = "DROP TABLE #{random_name} CASCADE"
      Postgrex.query!(db_conn, query, [])
      Realtime.Tenants.Connect.shutdown(@external_id)
      :timer.sleep(500)
    end)

    context
    |> Map.put(:db_conn, db_conn)
    |> Map.put(:table_name, random_name)
  end
end
