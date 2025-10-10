defmodule Realtime.Integration.RtChannelTest do
  # async: false due to the fact that multiple operations against the same tenant and usage of mocks
  # Also using dev_tenant due to distributed test
  alias Realtime.Api
  use RealtimeWeb.ConnCase, async: false
  use Mimic
  import ExUnit.CaptureLog
  import Generators

  setup :set_mimic_global

  require Logger

  alias Extensions.PostgresCdcRls

  alias Phoenix.Socket.Message
  alias Phoenix.Socket.V1

  alias Postgrex

  alias Realtime.Api.Tenant
  alias Realtime.Database
  alias Realtime.Integration.WebsocketClient
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.ReplicationConnection

  alias RealtimeWeb.RealtimeChannel.Tracker
  alias RealtimeWeb.SocketDisconnect

  @moduletag :capture_log
  @port 4003
  @serializer V1.JSONSerializer

  Application.put_env(:phoenix, TestEndpoint,
    https: false,
    http: [port: @port],
    debug_errors: false,
    server: true,
    pubsub_server: __MODULE__,
    secret_key_base: String.duplicate("a", 64)
  )

  setup_all do
    capture_log(fn -> start_supervised!(TestEndpoint) end)
    start_supervised!({Phoenix.PubSub, name: __MODULE__})
    :ok
  end

  setup [:mode]

  describe "postgres changes" do
    setup %{tenant: tenant} do
      {:ok, conn} = Database.connect(tenant, "realtime_test")

      Database.transaction(conn, fn db_conn ->
        queries = [
          "drop table if exists public.test",
          "drop publication if exists supabase_realtime_test",
          "create sequence if not exists test_id_seq;",
          """
          create table if not exists "public"."test" (
          "id" int4 not null default nextval('test_id_seq'::regclass),
          "details" text,
          primary key ("id"));
          """,
          "grant all on table public.test to anon;",
          "grant all on table public.test to postgres;",
          "grant all on table public.test to authenticated;",
          "create publication supabase_realtime_test for all tables"
        ]

        Enum.each(queries, &Postgrex.query!(db_conn, &1, []))
      end)

      :ok
    end

    test "error subscribing", %{tenant: tenant} do
      {:ok, conn} = Database.connect(tenant, "realtime_test")

      # Let's drop the publication to cause an error
      Database.transaction(conn, fn db_conn ->
        Postgrex.query!(db_conn, "drop publication if exists supabase_realtime_test")
      end)

      {socket, _} = get_connection(tenant)
      topic = "realtime:any"
      config = %{postgres_changes: [%{event: "INSERT", schema: "public"}]}

      log =
        capture_log(fn ->
          WebsocketClient.join(socket, topic, %{config: config})

          assert_receive %Message{
                           event: "system",
                           payload: %{
                             "channel" => "any",
                             "extension" => "postgres_changes",
                             "message" =>
                               "{:error, \"Unable to subscribe to changes with given parameters. Please check Realtime is enabled for the given connect parameters: [event: INSERT, schema: public]\"}",
                             "status" => "error"
                           },
                           ref: nil,
                           topic: ^topic
                         },
                         8000
        end)

      assert log =~ "RealtimeDisabledForConfiguration"
      assert log =~ "Unable to subscribe to changes with given parameters"
    end

    test "handle insert", %{tenant: tenant} do
      {socket, _} = get_connection(tenant)
      topic = "realtime:any"
      config = %{postgres_changes: [%{event: "INSERT", schema: "public"}]}

      WebsocketClient.join(socket, topic, %{config: config})
      sub_id = :erlang.phash2(%{"event" => "INSERT", "schema" => "public"})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "response" => %{
                           "postgres_changes" => [
                             %{"event" => "INSERT", "id" => ^sub_id, "schema" => "public"}
                           ]
                         },
                         "status" => "ok"
                       },
                       topic: ^topic
                     },
                     200

      assert_receive %Phoenix.Socket.Message{event: "presence_state", payload: %{}, topic: ^topic}, 500

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

      {:ok, _, conn} = PostgresCdcRls.get_manager_conn(tenant.external_id)
      %{rows: [[id]]} = Postgrex.query!(conn, "insert into test (details) values ('test') returning id", [])

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
                           "record" => %{"details" => "test", "id" => ^id},
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
    end

    test "handle update", %{tenant: tenant} do
      {socket, _} = get_connection(tenant)
      topic = "realtime:any"
      config = %{postgres_changes: [%{event: "UPDATE", schema: "public"}]}

      WebsocketClient.join(socket, topic, %{config: config})
      sub_id = :erlang.phash2(%{"event" => "UPDATE", "schema" => "public"})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "response" => %{
                           "postgres_changes" => [
                             %{"event" => "UPDATE", "id" => ^sub_id, "schema" => "public"}
                           ]
                         },
                         "status" => "ok"
                       },
                       ref: "1",
                       topic: ^topic
                     },
                     200

      assert_receive %Phoenix.Socket.Message{event: "presence_state", payload: %{}, topic: ^topic}, 500

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

      {:ok, _, conn} = PostgresCdcRls.get_manager_conn(tenant.external_id)
      %{rows: [[id]]} = Postgrex.query!(conn, "insert into test (details) values ('test') returning id", [])

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
    end

    test "handle delete", %{tenant: tenant} do
      {socket, _} = get_connection(tenant)
      topic = "realtime:any"
      config = %{postgres_changes: [%{event: "DELETE", schema: "public"}]}

      WebsocketClient.join(socket, topic, %{config: config})
      sub_id = :erlang.phash2(%{"event" => "DELETE", "schema" => "public"})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "response" => %{
                           "postgres_changes" => [
                             %{"event" => "DELETE", "id" => ^sub_id, "schema" => "public"}
                           ]
                         },
                         "status" => "ok"
                       },
                       ref: "1",
                       topic: ^topic
                     },
                     200

      assert_receive %Phoenix.Socket.Message{event: "presence_state", payload: %{}, topic: ^topic}, 500

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

      {:ok, _, conn} = PostgresCdcRls.get_manager_conn(tenant.external_id)
      %{rows: [[id]]} = Postgrex.query!(conn, "insert into test (details) values ('test') returning id", [])
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

    test "handle wildcard", %{tenant: tenant} do
      {socket, _} = get_connection(tenant)
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

      assert_receive %Phoenix.Socket.Message{event: "presence_state", payload: %{}, topic: ^topic}, 500

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

      {:ok, _, conn} = PostgresCdcRls.get_manager_conn(tenant.external_id)
      %{rows: [[id]]} = Postgrex.query!(conn, "insert into test (details) values ('test') returning id", [])

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
                           "record" => %{"id" => ^id},
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

    test "handle nil postgres changes params as empty param changes", %{tenant: tenant} do
      {socket, _} = get_connection(tenant)
      topic = "realtime:any"
      config = %{postgres_changes: [nil]}

      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 200
      assert_receive %Phoenix.Socket.Message{event: "presence_state", payload: %{}, topic: ^topic}, 500

      refute_receive %Message{
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
                     1000
    end
  end

  describe "handle broadcast extension" do
    setup [:rls_context]

    test "public broadcast", %{tenant: tenant} do
      {socket, _} = get_connection(tenant)
      config = %{broadcast: %{self: true}, private: false}
      topic = "realtime:any"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, topic, "broadcast", payload)

      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic}, 500
    end

    test "broadcast to another tenant does not get mixed up", %{tenant: tenant} do
      {socket, _} = get_connection(tenant)
      config = %{broadcast: %{self: false}, private: false}
      topic = "realtime:any"
      WebsocketClient.join(socket, topic, %{config: config})

      other_tenant = Containers.checkout_tenant(run_migrations: true)

      {other_socket, _} = get_connection(other_tenant)
      WebsocketClient.join(other_socket, topic, %{config: config})

      # Both sockets joined
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}
      assert_receive %Message{event: "presence_state"}

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, topic, "broadcast", payload)

      # No message received
      refute_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic}, 500
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "private broadcast with valid channel with permissions sends message", %{tenant: tenant, topic: topic} do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: true}
      topic = "realtime:#{topic}"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, topic, "broadcast", payload)

      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic}
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence],
         mode: :distributed
    test "private broadcast with valid channel with permissions sends message using a remote node (phoenix adapter)", %{
      tenant: tenant,
      topic: topic
    } do
      {:ok, token} =
        generate_token(tenant, %{exp: System.system_time(:second) + 1000, role: "authenticated", sub: random_string()})

      {:ok, remote_socket} = WebsocketClient.connect(self(), uri(tenant, 4012), @serializer, [{"x-api-key", token}])
      {:ok, socket} = WebsocketClient.connect(self(), uri(tenant), @serializer, [{"x-api-key", token}])

      config = %{broadcast: %{self: false}, private: true}
      topic = "realtime:#{topic}"

      WebsocketClient.join(remote_socket, topic, %{config: config})
      WebsocketClient.join(socket, topic, %{config: config})

      # Send through one socket and receive through the other (self: false)
      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, topic, "broadcast", payload)

      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic}, 500
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence],
         mode: :distributed
    test "private broadcast with valid channel with permissions sends message using a remote node", %{
      tenant: tenant,
      topic: topic
    } do
      {:ok, token} =
        generate_token(tenant, %{exp: System.system_time(:second) + 1000, role: "authenticated", sub: random_string()})

      {:ok, remote_socket} = WebsocketClient.connect(self(), uri(tenant, 4012), @serializer, [{"x-api-key", token}])
      {:ok, socket} = WebsocketClient.connect(self(), uri(tenant), @serializer, [{"x-api-key", token}])

      config = %{broadcast: %{self: false}, private: true}
      topic = "realtime:#{topic}"

      WebsocketClient.join(remote_socket, topic, %{config: config})
      WebsocketClient.join(socket, topic, %{config: config})

      # Send through one socket and receive through the other (self: false)
      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, topic, "broadcast", payload)
      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic}, 500
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence],
         topic: "topic"
    test "private broadcast with valid channel a colon character sends message and won't intercept in public channels",
         %{topic: topic, tenant: tenant} do
      {anon_socket, _} = get_connection(tenant, "anon")
      {socket, _} = get_connection(tenant, "authenticated")
      valid_topic = "realtime:#{topic}"
      malicious_topic = "realtime:private:#{topic}"

      WebsocketClient.join(socket, valid_topic, %{config: %{broadcast: %{self: true}, private: true}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^valid_topic}, 300
      assert_receive %Message{event: "presence_state"}

      WebsocketClient.join(anon_socket, malicious_topic, %{config: %{broadcast: %{self: true}, private: false}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^malicious_topic}, 300
      assert_receive %Message{event: "presence_state"}

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, valid_topic, "broadcast", payload)

      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^valid_topic}, 500
      refute_receive %Message{event: "broadcast"}
    end

    @tag policies: [:authenticated_read_broadcast_and_presence]
    test "private broadcast with valid channel no write permissions won't send message but will receive message", %{
      tenant: tenant,
      topic: topic
    } do
      config = %{broadcast: %{self: true}, private: true}
      topic = "realtime:#{topic}"

      {service_role_socket, _} = get_connection(tenant, "service_role")
      WebsocketClient.join(service_role_socket, topic, %{config: config})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      {socket, _} = get_connection(tenant, "authenticated")
      WebsocketClient.join(socket, topic, %{config: config})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}

      WebsocketClient.send_event(socket, topic, "broadcast", payload)
      refute_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic}, 500

      WebsocketClient.send_event(service_role_socket, topic, "broadcast", payload)
      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic}, 500
      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic}, 500
    end

    @tag policies: []
    test "private broadcast with valid channel and no read permissions won't join", %{tenant: tenant, topic: topic} do
      config = %{private: true}
      expected = "Unauthorized: You do not have permissions to read from this Channel topic: #{topic}"

      topic = "realtime:#{topic}"
      {socket, _} = get_connection(tenant, "authenticated")

      log =
        capture_log(fn ->
          WebsocketClient.join(socket, topic, %{config: config})

          assert_receive %Message{
                           topic: ^topic,
                           event: "phx_reply",
                           payload: %{
                             "response" => %{
                               "reason" => ^expected
                             },
                             "status" => "error"
                           }
                         },
                         300

          refute_receive %Message{event: "phx_reply", topic: ^topic}, 300
          refute_receive %Message{event: "presence_state"}, 300
        end)

      assert log =~ expected
    end

    @tag policies: [:authenticated_read_broadcast_and_presence]
    test "handles lack of connection to database error on private channels", %{tenant: tenant, topic: topic} do
      topic = "realtime:#{topic}"
      {socket, _} = get_connection(tenant, "authenticated")
      WebsocketClient.join(socket, topic, %{config: %{broadcast: %{self: true}, private: true}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      {service_role_socket, _} = get_connection(tenant, "service_role")
      WebsocketClient.join(service_role_socket, topic, %{config: %{broadcast: %{self: false}, private: true}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      log =
        capture_log(fn ->
          :syn.update_registry(Connect, tenant.external_id, fn _pid, meta -> %{meta | conn: nil} end)
          payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
          WebsocketClient.send_event(service_role_socket, topic, "broadcast", payload)
          # Waiting more than 15 seconds as this is the amount of time we will wait for the Connection to be ready
          refute_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic}, 16000
        end)

      assert log =~ "UnableToHandleBroadcast"
    end

    @tag policies: []
    test "lack of connection to database error does not impact public channels", %{tenant: tenant, topic: topic} do
      topic = "realtime:#{topic}"
      {socket, _} = get_connection(tenant, "authenticated")
      WebsocketClient.join(socket, topic, %{config: %{broadcast: %{self: true}, private: false}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      {service_role_socket, _} = get_connection(tenant, "service_role")
      WebsocketClient.join(service_role_socket, topic, %{config: %{broadcast: %{self: false}, private: false}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      log =
        capture_log(fn ->
          :syn.update_registry(Connect, tenant.external_id, fn _pid, meta -> %{meta | conn: nil} end)
          payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
          WebsocketClient.send_event(service_role_socket, topic, "broadcast", payload)
          assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic}, 500
        end)

      refute log =~ "UnableToHandleBroadcast"
    end
  end

  describe "handle presence extension" do
    setup [:rls_context]

    test "public presence", %{tenant: tenant} do
      {socket, _} = get_connection(tenant)
      config = %{presence: %{key: "", enabled: true}, private: false}
      topic = "realtime:any"

      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state", payload: %{}, topic: ^topic}, 500

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_96", t: 1814.7000000029802}
      }

      WebsocketClient.send_event(socket, topic, "presence", payload)

      assert_receive %Message{event: "presence_diff", payload: %{"joins" => joins, "leaves" => %{}}, topic: ^topic}

      join_payload = joins |> Map.values() |> hd() |> get_in(["metas"]) |> hd()
      assert get_in(join_payload, ["name"]) == payload.payload.name
      assert get_in(join_payload, ["t"]) == payload.payload.t
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "private presence with read and write permissions will be able to track and receive presence changes",
         %{tenant: tenant, topic: topic} do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{presence: %{key: "", enabled: true}, private: true}
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

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence],
         mode: :distributed
    test "private presence with read and write permissions will be able to track and receive presence changes using a remote node",
         %{tenant: tenant, topic: topic} do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{presence: %{key: "", enabled: true}, private: true}
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
         %{tenant: tenant, topic: topic} do
      {socket, _} = get_connection(tenant, "authenticated")
      {secondary_socket, _} = get_connection(tenant, "service_role")
      config = fn key -> %{presence: %{key: key, enabled: true}, private: true} end
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

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "handles lack of connection to database error on private channels", %{tenant: tenant, topic: topic} do
      topic = "realtime:#{topic}"
      {socket, _} = get_connection(tenant, "authenticated")
      WebsocketClient.join(socket, topic, %{config: %{private: true, presence: %{enabled: true}}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      log =
        capture_log(fn ->
          :syn.update_registry(Connect, tenant.external_id, fn _pid, meta -> %{meta | conn: nil} end)
          payload = %{type: "presence", event: "TRACK", payload: %{name: "realtime_presence_96", t: 1814.7000000029802}}
          WebsocketClient.send_event(socket, topic, "presence", payload)

          refute_receive %Message{event: "presence_diff"}, 500
          # Waiting more than 5 seconds as this is the amount of time we will wait for the Connection to be ready
          refute_receive %Message{event: "phx_leave", topic: ^topic}, 16000
        end)

      assert log =~ "UnableToHandlePresence"
    end

    @tag policies: []
    test "lack of connection to database error does not impact public channels", %{tenant: tenant, topic: topic} do
      topic = "realtime:#{topic}"
      {socket, _} = get_connection(tenant, "authenticated")
      WebsocketClient.join(socket, topic, %{config: %{private: false, presence: %{enabled: true}}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      log =
        capture_log(fn ->
          :syn.update_registry(Connect, tenant.external_id, fn _pid, meta -> %{meta | conn: nil} end)
          payload = %{type: "presence", event: "TRACK", payload: %{name: "realtime_presence_96", t: 1814.7000000029802}}
          WebsocketClient.send_event(socket, topic, "presence", payload)

          assert_receive %Message{event: "presence_diff"}, 500
          refute_receive %Message{event: "phx_leave", topic: ^topic}
        end)

      refute log =~ "UnableToHandlePresence"
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]

    test "presence enabled if param enabled is set in configuration for private channels", %{
      tenant: tenant,
      topic: topic
    } do
      {socket, _} = get_connection(tenant, "authenticated")
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: %{private: true, presence: %{enabled: true}}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]

    test "presence disabled if param 'enabled' is set to false in configuration for private channels", %{
      tenant: tenant,
      topic: topic
    } do
      {socket, _} = get_connection(tenant, "authenticated")
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: %{private: true, presence: %{enabled: false}}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      refute_receive %Message{event: "presence_state"}, 500
    end

    test "presence enabled if param enabled is set in configuration for public channels", %{
      tenant: tenant,
      topic: topic
    } do
      {socket, _} = get_connection(tenant, "authenticated")
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: %{private: false, presence: %{enabled: true}}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500
    end

    test "presence disabled if param 'enabled' is set to false in configuration for public channels", %{
      tenant: tenant,
      topic: topic
    } do
      {socket, _} = get_connection(tenant, "authenticated")
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: %{private: false, presence: %{enabled: false}}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      refute_receive %Message{event: "presence_state"}, 500
    end

    test "presence automatically enabled when user sends track message for public channel", %{tenant: tenant} do
      {socket, _} = get_connection(tenant)
      config = %{presence: %{key: "", enabled: false}, private: false}
      topic = "realtime:any"

      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      refute_receive %Message{event: "presence_state"}, 500

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_96", t: 1814.7000000029802}
      }

      WebsocketClient.send_event(socket, topic, "presence", payload)

      assert_receive %Message{event: "presence_diff", payload: %{"joins" => joins, "leaves" => %{}}, topic: ^topic}

      join_payload = joins |> Map.values() |> hd() |> get_in(["metas"]) |> hd()
      assert get_in(join_payload, ["name"]) == payload.payload.name
      assert get_in(join_payload, ["t"]) == payload.payload.t
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "presence automatically enabled when user sends track message for private channel",
         %{tenant: tenant, topic: topic} do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{presence: %{key: "", enabled: false}, private: true}
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: config})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      refute_receive %Message{event: "presence_state"}, 500

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_96", t: 1814.7000000029802}
      }

      WebsocketClient.send_event(socket, topic, "presence", payload)

      assert_receive %Message{event: "presence_diff", payload: %{"joins" => joins, "leaves" => %{}}, topic: ^topic}, 500
      join_payload = joins |> Map.values() |> hd() |> get_in(["metas"]) |> hd()
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
    test "badly formatted jwt token", %{tenant: tenant} do
      log =
        capture_log(fn ->
          WebsocketClient.connect(self(), uri(tenant), @serializer, [{"x-api-key", "bad_token"}])
        end)

      assert log =~ "MalformedJWT: The token provided is not a valid JWT"
    end

    test "invalid JWT with expired token", %{tenant: tenant} do
      log =
        capture_log(fn ->
          get_connection(tenant, "authenticated", %{:exp => System.system_time(:second) - 1000}, %{log_level: :info})
        end)

      assert log =~ "InvalidJWTToken: Token has expired"
    end

    test "token required the role key", %{tenant: tenant} do
      {:ok, token} = token_no_role(tenant)

      assert {:error, %{status_code: 403}} =
               WebsocketClient.connect(self(), uri(tenant), @serializer, [{"x-api-key", token}])
    end

    test "handles connection with valid api-header but ignorable access_token payload", %{tenant: tenant, topic: topic} do
      realtime_topic = "realtime:#{topic}"

      log =
        capture_log(fn ->
          {:ok, token} =
            generate_token(tenant, %{
              exp: System.system_time(:second) + 1000,
              role: "authenticated",
              sub: random_string()
            })

          {:ok, socket} = WebsocketClient.connect(self(), uri(tenant), @serializer, [{"x-api-key", token}])

          WebsocketClient.join(socket, realtime_topic, %{
            config: %{broadcast: %{self: true}, private: false},
            access_token: "sb_#{random_string()}"
          })

          assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
          assert_receive %Message{event: "presence_state"}, 500
        end)

      refute log =~ "MalformedJWT: The token provided is not a valid JWT"
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "on new access_token and channel is private policies are reevaluated for read policy",
         %{tenant: tenant, topic: topic} do
      {socket, access_token} = get_connection(tenant, "authenticated")

      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{
        config: %{broadcast: %{self: true}, private: true},
        access_token: access_token
      })

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

      {:ok, new_token} = token_valid(tenant, "anon")

      WebsocketClient.send_event(socket, realtime_topic, "access_token", %{"access_token" => new_token})

      error_message = "You do not have permissions to read from this Channel topic: #{topic}"

      assert_receive %Message{
        event: "system",
        payload: %{"channel" => ^topic, "extension" => "system", "message" => ^error_message, "status" => "error"},
        topic: ^realtime_topic
      }

      assert_receive %Message{event: "phx_close", topic: ^realtime_topic}
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "on new access_token and channel is private policies are reevaluated for write policy", %{
      topic: topic,
      tenant: tenant
    } do
      {socket, access_token} = get_connection(tenant, "authenticated")
      realtime_topic = "realtime:#{topic}"
      config = %{broadcast: %{self: true}, private: true}
      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

      # Checks first send which will set write policy to true
      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, realtime_topic, "broadcast", payload)

      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^realtime_topic}, 500

      # RLS policies changed to only allow read
      {:ok, db_conn} = Database.connect(tenant, "realtime_test")
      clean_table(db_conn, "realtime", "messages")
      create_rls_policies(db_conn, [:authenticated_read_broadcast_and_presence], %{topic: topic})

      # Set new token to recheck policies
      {:ok, new_token} =
        generate_token(tenant, %{exp: System.system_time(:second) + 1000, role: "authenticated", sub: random_string()})

      WebsocketClient.send_event(socket, realtime_topic, "access_token", %{"access_token" => new_token})

      # Send message to be ignored
      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, realtime_topic, "broadcast", payload)

      refute_receive %Message{
                       event: "broadcast",
                       payload: ^payload,
                       topic: ^realtime_topic
                     },
                     1500
    end

    test "on new access_token and channel is public policies are not reevaluated", %{tenant: tenant, topic: topic} do
      {socket, access_token} = get_connection(tenant, "authenticated")
      {:ok, new_token} = token_valid(tenant, "anon")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

      WebsocketClient.send_event(socket, realtime_topic, "access_token", %{"access_token" => new_token})

      refute_receive %Message{}
    end

    test "on empty string access_token the socket sends an error message", %{tenant: tenant, topic: topic} do
      {socket, access_token} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

      WebsocketClient.send_event(socket, realtime_topic, "access_token", %{"access_token" => ""})

      assert_receive %Message{
        topic: ^realtime_topic,
        event: "system",
        payload: %{
          "extension" => "system",
          "message" => msg,
          "status" => "error"
        }
      }

      assert_receive %Message{event: "phx_close"}
      assert msg =~ "The token provided is not a valid JWT"
    end

    test "on expired access_token the socket sends an error message", %{tenant: tenant, topic: topic} do
      sub = random_string()

      {socket, access_token} = get_connection(tenant, "authenticated", %{sub: sub})

      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500
      {:ok, token} = generate_token(tenant, %{:exp => System.system_time(:second) - 1000, sub: sub})

      log =
        capture_log([log_level: :warning], fn ->
          WebsocketClient.send_event(socket, realtime_topic, "access_token", %{"access_token" => token})

          assert_receive %Message{
            topic: ^realtime_topic,
            event: "system",
            payload: %{"extension" => "system", "message" => "Token has expired 1000 seconds ago", "status" => "error"}
          }
        end)

      assert log =~ "ChannelShutdown: Token has expired"
    end

    test "ChannelShutdown include sub if available in jwt claims", %{tenant: tenant, topic: topic} do
      exp = System.system_time(:second) + 10_000

      {socket, access_token} = get_connection(tenant, "authenticated", %{exp: exp}, %{log_level: :warning})
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"
      sub = random_string()
      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})
      {:ok, token} = generate_token(tenant, %{:exp => System.system_time(:second) - 1000, sub: sub})

      log =
        capture_log([level: :warning], fn ->
          WebsocketClient.send_event(socket, realtime_topic, "access_token", %{"access_token" => token})

          assert_receive %Message{event: "system"}, 1000
        end)

      assert log =~ "ChannelShutdown"
      assert log =~ "sub=#{sub}"
    end

    test "missing claims close connection", %{tenant: tenant, topic: topic} do
      {socket, access_token} = get_connection(tenant, "authenticated")

      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500
      {:ok, token} = generate_token(tenant, %{:exp => System.system_time(:second) + 2000})

      # Update token to be a near expiring token
      WebsocketClient.send_event(socket, realtime_topic, "access_token", %{"access_token" => token})

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

    test "checks token periodically", %{tenant: tenant, topic: topic} do
      {socket, access_token} = get_connection(tenant, "authenticated")

      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

      {:ok, token} = generate_token(tenant, %{:exp => System.system_time(:second) + 2, role: "authenticated"})

      # Update token to be a near expiring token
      WebsocketClient.send_event(socket, realtime_topic, "access_token", %{"access_token" => token})

      # Awaits to see if connection closes automatically
      assert_receive %Message{
                       event: "system",
                       payload: %{"extension" => "system", "message" => msg, "status" => "error"}
                     },
                     3000

      assert_receive %Message{event: "phx_close"}

      assert msg =~ "Token has expired"
    end

    test "token expires in between joins", %{tenant: tenant, topic: topic} do
      {socket, access_token} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

      {:ok, access_token} = generate_token(tenant, %{:exp => System.system_time(:second) + 1, role: "authenticated"})

      # token expires in between joins so it needs to be handled by the channel and not the socket
      Process.sleep(1000)
      realtime_topic = "realtime:#{topic}"

      log =
        capture_log(fn ->
          WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

          assert_receive %Message{
                           event: "phx_reply",
                           payload: %{
                             "status" => "error",
                             "response" => %{"reason" => "InvalidJWTToken: Token has expired 0 seconds ago"}
                           },
                           topic: ^realtime_topic
                         },
                         500
        end)

      assert_receive %Message{event: "phx_close"}
      assert log =~ "#{tenant.external_id}"
    end

    test "token loses claims in between joins", %{tenant: tenant, topic: topic} do
      {socket, access_token} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

      {:ok, access_token} = generate_token(tenant, %{:exp => System.system_time(:second) + 10})

      # token breaks claims in between joins so it needs to be handled by the channel and not the socket
      realtime_topic = "realtime:#{topic}"
      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "status" => "error",
                         "response" => %{
                           "reason" => "InvalidJWTToken: Fields `role` and `exp` are required in JWT"
                         }
                       },
                       topic: ^realtime_topic
                     },
                     500

      assert_receive %Message{event: "phx_close"}
    end

    test "token is badly formatted in between joins", %{tenant: tenant, topic: topic} do
      {socket, access_token} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

      # token becomes a string in between joins so it needs to be handled by the channel and not the socket
      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: "potato"})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "status" => "error",
                         "response" => %{
                           "reason" => "MalformedJWT: The token provided is not a valid JWT"
                         }
                       },
                       topic: ^realtime_topic
                     },
                     500

      assert_receive %Message{event: "phx_close"}
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "handles RPC error on token refreshed", %{tenant: tenant, topic: topic} do
      Authorization
      |> expect(:get_read_authorizations, fn conn, db_conn, context ->
        call_original(Authorization, :get_read_authorizations, [conn, db_conn, context])
      end)
      |> expect(:get_read_authorizations, fn _, _, _ -> {:error, "RPC Error"} end)

      {socket, access_token} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: true}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Phoenix.Socket.Message{event: "phx_reply"}, 500
      assert_receive %Phoenix.Socket.Message{event: "presence_state"}, 500

      # Update token to force update
      {:ok, access_token} =
        generate_token(tenant, %{:exp => System.system_time(:second) + 1000, role: "authenticated"})

      log =
        capture_log([log_level: :warning], fn ->
          WebsocketClient.send_event(socket, realtime_topic, "access_token", %{"access_token" => access_token})

          assert_receive %Phoenix.Socket.Message{
                           event: "system",
                           payload: %{
                             "status" => "error",
                             "extension" => "system",
                             "message" => "Realtime was unable to connect to the project database"
                           },
                           topic: ^realtime_topic
                         },
                         500

          assert_receive %Phoenix.Socket.Message{event: "phx_close", topic: ^realtime_topic}
        end)

      assert log =~ "Realtime was unable to connect to the project database"
    end

    test "on sb prefixed access_token the socket ignores the message and respects JWT expiry time", %{
      tenant: tenant,
      topic: topic
    } do
      sub = random_string()

      {socket, access_token} =
        get_connection(tenant, "authenticated", %{sub: sub, exp: System.system_time(:second) + 5})

      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config, access_token: access_token})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

      WebsocketClient.send_event(socket, realtime_topic, "access_token", %{
        "access_token" => "sb_publishable_-fake_key"
      })

      # Check if the new token does not trigger a shutdown
      refute_receive %Message{event: "system", topic: ^realtime_topic}, 100

      # Await to check if channel respects token expiry time
      assert_receive %Message{
                       event: "system",
                       payload: %{"extension" => "system", "message" => msg, "status" => "error"},
                       topic: ^realtime_topic
                     },
                     5000

      assert_receive %Message{event: "phx_close", topic: ^realtime_topic}
      msg =~ "Token has expired"
    end
  end

  describe "handle broadcast changes" do
    setup [:rls_context, :setup_trigger]

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "broadcast insert event changes on insert in table with trigger", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn,
      table_name: table_name
    } do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: true}
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

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
                     1000
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence],
         requires_data: true
    test "broadcast update event changes on update in table with trigger", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn,
      table_name: table_name
    } do
      value = random_string()
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: true}
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

      new_value = random_string()

      Postgrex.query!(db_conn, "INSERT INTO #{table_name} (details) VALUES ($1)", [value])
      Postgrex.query!(db_conn, "UPDATE #{table_name} SET details = $1 WHERE details = $2", [new_value, value])

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
                     1000
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "broadcast delete event changes on delete in table with trigger", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn,
      table_name: table_name
    } do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: true}
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

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
                     1000
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "broadcast event when function 'send' is called with private topic", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn
    } do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: true}
      full_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, full_topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

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
                     1000
    end

    test "broadcast event when function 'send' is called with public topic", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn
    } do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      full_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, full_topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

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
                     1000
    end
  end

  describe "only private channels" do
    setup [:rls_context]

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "user with only private channels enabled will not be able to join public channels", %{
      tenant: tenant,
      topic: topic
    } do
      change_tenant_configuration(tenant, :private_only, true)
      on_exit(fn -> change_tenant_configuration(tenant, :private_only, false) end)
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      topic = "realtime:#{topic}"

      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "response" => %{
                           "reason" => "PrivateOnly: This project only allows private channels"
                         },
                         "status" => "error"
                       }
                     },
                     500
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "user with only private channels enabled will be able to join private channels", %{
      tenant: tenant,
      topic: topic
    } do
      change_tenant_configuration(tenant, :private_only, true)
      on_exit(fn -> change_tenant_configuration(tenant, :private_only, false) end)

      Process.sleep(100)

      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: true}
      topic = "realtime:#{topic}"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
    end
  end

  describe "socket disconnect" do
    setup [:rls_context]

    test "tenant already suspended", %{topic: _topic} do
      tenant = Containers.checkout_tenant(run_migrations: true)

      log =
        capture_log(fn ->
          {:ok, _} = Realtime.Api.update_tenant(tenant, %{suspend: true})
          {:error, %Mint.WebSocket.UpgradeFailureError{}} = get_connection(tenant, "anon")
          refute_receive _any
        end)

      assert log =~ "RealtimeDisabledForTenant"
    end

    test "on jwks the socket closes and sends a system message", %{tenant: tenant, topic: topic} do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500
      tenant = Tenants.get_tenant_by_external_id(tenant.external_id)
      Realtime.Api.update_tenant(tenant, %{jwt_jwks: %{keys: ["potato"]}})

      assert_process_down(socket)
    end

    test "on jwt_secret the socket closes and sends a system message", %{tenant: tenant, topic: topic} do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

      tenant = Tenants.get_tenant_by_external_id(tenant.external_id)
      Realtime.Api.update_tenant(tenant, %{jwt_secret: "potato"})

      assert_process_down(socket)
    end

    test "on private_only the socket closes and sends a system message", %{tenant: tenant, topic: topic} do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

      tenant = Tenants.get_tenant_by_external_id(tenant.external_id)
      Realtime.Api.update_tenant(tenant, %{private_only: true})

      assert_process_down(socket)
    end

    test "on other param changes the socket won't close and no message is sent", %{tenant: tenant, topic: topic} do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

      tenant = Tenants.get_tenant_by_external_id(tenant.external_id)
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

      Process.sleep(500)
      assert :ok = WebsocketClient.send_heartbeat(socket)
    end

    test "invalid JWT with expired token", %{tenant: tenant} do
      log =
        capture_log(fn ->
          get_connection(tenant, "authenticated", %{:exp => System.system_time(:second) - 1000}, %{log_level: :info})
        end)

      assert log =~ "InvalidJWTToken: Token has expired"
    end

    test "check registry of SocketDisconnect and on distribution called, kill socket", %{tenant: tenant} do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: false}

      for _ <- 1..10 do
        topic = "realtime:#{random_string()}"
        WebsocketClient.join(socket, topic, %{config: config})

        assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 500
        assert_receive %Message{event: "presence_state", topic: ^topic}, 500
      end

      assert :ok = WebsocketClient.send_heartbeat(socket)

      SocketDisconnect.distributed_disconnect(tenant)

      assert_process_down(socket)
    end
  end

  describe "rate limits" do
    setup [:rls_context]

    test "max_concurrent_users limit respected", %{tenant: tenant} do
      %{max_concurrent_users: max_concurrent_users} = Tenants.get_tenant_by_external_id(tenant.external_id)
      change_tenant_configuration(tenant, :max_concurrent_users, 1)

      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{random_string()}"
      WebsocketClient.join(socket, realtime_topic, %{config: config})
      WebsocketClient.join(socket, realtime_topic, %{config: config})

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "response" => %{
                           "reason" => "ConnectionRateLimitReached: Too many connected users"
                         },
                         "status" => "error"
                       }
                     },
                     500

      assert_receive %Message{event: "phx_close"}

      change_tenant_configuration(tenant, :max_concurrent_users, max_concurrent_users)
    end

    test "max_events_per_second limit respected", %{tenant: tenant} do
      %{max_events_per_second: max_events_per_second} = Tenants.get_tenant_by_external_id(tenant.external_id)
      on_exit(fn -> change_tenant_configuration(tenant, :max_events_per_second, max_events_per_second) end)
      RateCounter.stop(tenant.external_id)

      log =
        capture_log(fn ->
          {socket, _} = get_connection(tenant, "authenticated")
          config = %{broadcast: %{self: true}, private: false, presence: %{enabled: false}}
          realtime_topic = "realtime:#{random_string()}"

          WebsocketClient.join(socket, realtime_topic, %{config: config})
          assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^realtime_topic}, 500

          for _ <- 1..1000, Process.alive?(socket) do
            WebsocketClient.send_event(socket, realtime_topic, "broadcast", %{})
            Process.sleep(10)
          end

          # Wait for the rate counter to run logger function
          Process.sleep(1500)
          assert_receive %Message{event: "phx_close"}
        end)

      assert log =~ "MessagePerSecondRateLimitReached"
    end

    test "max_channels_per_client limit respected", %{tenant: tenant} do
      %{max_events_per_second: max_concurrent_users} = Tenants.get_tenant_by_external_id(tenant.external_id)
      change_tenant_configuration(tenant, :max_channels_per_client, 1)

      {socket, _} = get_connection(tenant, "authenticated")
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

      assert_receive %Message{event: "presence_state", topic: ^realtime_topic_1}, 500

      assert_receive %Message{
                       event: "phx_reply",
                       payload: %{
                         "status" => "error",
                         "response" => %{
                           "reason" => "ChannelRateLimitReached: Too many channels"
                         }
                       },
                       topic: ^realtime_topic_2
                     },
                     500

      refute_receive %Message{event: "phx_reply", topic: ^realtime_topic_2}, 500
      refute_receive %Message{event: "presence_state", topic: ^realtime_topic_2}, 500

      change_tenant_configuration(tenant, :max_channels_per_client, max_concurrent_users)
    end

    test "max_joins_per_second limit respected", %{tenant: tenant} do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      realtime_topic = "realtime:#{random_string()}"

      log =
        capture_log(fn ->
          # Burst of joins that won't be blocked as RateCounter tick won't run
          for _ <- 1..300 do
            WebsocketClient.join(socket, realtime_topic, %{config: config})
          end

          # Wait for RateCounter tick
          Process.sleep(1000)
          # These ones will be blocked
          for _ <- 1..300 do
            WebsocketClient.join(socket, realtime_topic, %{config: config})
          end

          assert_receive %Message{
                           event: "phx_reply",
                           payload: %{
                             "response" => %{
                               "reason" => "ClientJoinRateLimitReached: Too many joins per second"
                             },
                             "status" => "error"
                           }
                         },
                         2000
        end)

      assert log =~
               "project=#{tenant.external_id} external_id=#{tenant.external_id} [critical] ClientJoinRateLimitReached: Too many joins per second"

      # Only one log message should be emitted
      # Splitting by the error message returns the error message and the rest of the log only
      assert length(String.split(log, "ClientJoinRateLimitReached")) == 2
    end
  end

  describe "authorization handling" do
    setup [:rls_context]

    @tag policies: [:read_matching_user_role, :write_matching_user_role], role: "anon"
    test "role policies are respected when accessing the channel", %{tenant: tenant} do
      {socket, _} = get_connection(tenant, "anon")
      config = %{broadcast: %{self: true}, private: true, presence: %{enabled: false}}
      topic = random_string()
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^realtime_topic}, 500

      {socket, _} = get_connection(tenant, "potato")
      topic = random_string()
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})
      refute_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^realtime_topic}, 500
    end

    @tag policies: [:authenticated_read_matching_user_sub, :authenticated_write_matching_user_sub],
         sub: Ecto.UUID.generate()
    test "sub policies are respected when accessing the channel", %{tenant: tenant, sub: sub} do
      {socket, _} = get_connection(tenant, "authenticated", %{sub: sub})
      config = %{broadcast: %{self: true}, private: true, presence: %{enabled: false}}
      topic = random_string()
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^realtime_topic}, 500

      {socket, _} = get_connection(tenant, "authenticated", %{sub: Ecto.UUID.generate()})
      topic = random_string()
      realtime_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, realtime_topic, %{config: config})
      refute_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^realtime_topic}, 500
    end

    @tag role: "authenticated",
         policies: [:broken_read_presence, :broken_write_presence]

    test "handle failing rls policy", %{tenant: tenant} do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: true}
      topic = random_string()
      realtime_topic = "realtime:#{topic}"

      log =
        capture_log(fn ->
          WebsocketClient.join(socket, realtime_topic, %{config: config})

          msg = "Unauthorized: You do not have permissions to read from this Channel topic: #{topic}"

          assert_receive %Message{
                           event: "phx_reply",
                           payload: %{
                             "response" => %{
                               "reason" => ^msg
                             },
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

  test "handle empty topic by closing the socket", %{tenant: tenant} do
    {socket, _} = get_connection(tenant, "authenticated")
    config = %{broadcast: %{self: true}, private: false}
    realtime_topic = "realtime:"

    WebsocketClient.join(socket, realtime_topic, %{config: config})

    assert_receive %Message{
                     event: "phx_reply",
                     payload: %{
                       "response" => %{
                         "reason" => "TopicNameRequired: You must provide a topic name"
                       },
                       "status" => "error"
                     }
                   },
                   500

    refute_receive %Message{event: "phx_reply"}
    refute_receive %Message{event: "presence_state"}
  end

  def handle_telemetry(event, %{sum: sum}, metadata, _) do
    tenant = metadata[:tenant]
    [key] = Enum.take(event, -1)

    Agent.update(TestCounter, fn state ->
      state = Map.put_new(state, tenant, %{joins: 0, events: 0, db_events: 0, presence_events: 0})
      update_in(state, [metadata[:tenant], key], fn v -> (v || 0) + sum end)
    end)
  end

  defp get_count(event, tenant) do
    [key] = Enum.take(event, -1)

    Agent.get(TestCounter, fn state -> get_in(state, [tenant, key]) || 0 end)
  end

  describe "billable events" do
    setup %{tenant: tenant} do
      events = [
        [:realtime, :rate_counter, :channel, :joins],
        [:realtime, :rate_counter, :channel, :events],
        [:realtime, :rate_counter, :channel, :db_events],
        [:realtime, :rate_counter, :channel, :presence_events]
      ]

      {:ok, _} =
        start_supervised(%{
          id: 1,
          start: {Agent, :start_link, [fn -> %{} end, [name: TestCounter]]}
        })

      RateCounter.stop(tenant.external_id)
      on_exit(fn -> :telemetry.detach(__MODULE__) end)
      :telemetry.attach_many(__MODULE__, events, &__MODULE__.handle_telemetry/4, [])

      {:ok, conn} = Database.connect(tenant, "realtime_test")

      # Setup for postgres changes
      Database.transaction(conn, fn db_conn ->
        queries = [
          "drop table if exists public.test",
          "drop publication if exists supabase_realtime_test",
          "create sequence if not exists test_id_seq;",
          """
          create table if not exists "public"."test" (
          "id" int4 not null default nextval('test_id_seq'::regclass),
          "details" text,
          primary key ("id"));
          """,
          "grant all on table public.test to anon;",
          "grant all on table public.test to postgres;",
          "grant all on table public.test to authenticated;",
          "create publication supabase_realtime_test for all tables"
        ]

        Enum.each(queries, &Postgrex.query!(db_conn, &1, []))
      end)

      :ok
    end

    test "join events", %{tenant: tenant} do
      external_id = tenant.external_id
      {socket, _} = get_connection(tenant)
      config = %{broadcast: %{self: true}, postgres_changes: [%{event: "*", schema: "public"}]}
      topic = "realtime:any"

      WebsocketClient.join(socket, topic, %{config: config})

      # Join events
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{topic: ^topic, event: "presence_state"}
      assert_receive %Message{topic: ^topic, event: "system"}, 5000

      # Wait for RateCounter to run
      Process.sleep(2000)

      # Expected billed
      # 1 joins due to two sockets
      # 1 presence events due to two sockets
      # 0 db events as no postgres changes used
      # 0 events broadcast is not used
      assert 1 = get_count([:realtime, :rate_counter, :channel, :joins], external_id)
      assert 1 = get_count([:realtime, :rate_counter, :channel, :presence_events], external_id)
      assert 0 = get_count([:realtime, :rate_counter, :channel, :db_events], external_id)
      assert 0 = get_count([:realtime, :rate_counter, :channel, :events], external_id)
    end

    test "broadcast events", %{tenant: tenant} do
      external_id = tenant.external_id
      {socket, _} = get_connection(tenant)
      config = %{broadcast: %{self: true}}
      topic = "realtime:any"

      WebsocketClient.join(socket, topic, %{config: config})

      # Join events
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{topic: ^topic, event: "presence_state"}

      # Add second client so we can test the "multiplication" of billable events
      {socket, _} = get_connection(tenant)
      WebsocketClient.join(socket, topic, %{config: config})

      # Join events
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{topic: ^topic, event: "presence_state"}

      # Broadcast event
      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}

      for _ <- 1..5 do
        WebsocketClient.send_event(socket, topic, "broadcast", payload)
        assert_receive %Message{topic: ^topic, event: "broadcast", payload: ^payload}
      end

      # Wait for RateCounter to run
      Process.sleep(2000)

      # Expected billed
      # 2 joins due to two sockets
      # 2 presence events due to two sockets
      # 0 db events as no postgres changes used
      # 15 events as 5 events sent, 5 events received on client 1 and 5 events received on client 2
      assert 2 = get_count([:realtime, :rate_counter, :channel, :joins], external_id)
      assert 2 = get_count([:realtime, :rate_counter, :channel, :presence_events], external_id)
      assert 0 = get_count([:realtime, :rate_counter, :channel, :db_events], external_id)
      assert 15 = get_count([:realtime, :rate_counter, :channel, :events], external_id)
    end

    test "presence events", %{tenant: tenant} do
      external_id = tenant.external_id
      {socket, _} = get_connection(tenant)
      config = %{broadcast: %{self: true}, presence: %{enabled: true}}
      topic = "realtime:any"

      WebsocketClient.join(socket, topic, %{config: config})

      # Join events
      assert_receive %Message{event: "phx_reply", topic: ^topic}, 1000
      assert_receive %Message{topic: ^topic, event: "presence_state"}, 1000

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_1", t: 1814.7000000029802}
      }

      WebsocketClient.send_event(socket, topic, "presence", payload)
      assert_receive %Message{event: "presence_diff", payload: %{"joins" => _, "leaves" => %{}}, topic: ^topic}

      # Presence events
      {socket, _} = get_connection(tenant, "authenticated")
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{topic: ^topic, event: "presence_state"}

      payload = %{
        type: "presence",
        event: "TRACK",
        payload: %{name: "realtime_presence_2", t: 1814.7000000029802}
      }

      WebsocketClient.send_event(socket, topic, "presence", payload)
      assert_receive %Message{event: "presence_diff", payload: %{"joins" => _, "leaves" => %{}}, topic: ^topic}
      assert_receive %Message{event: "presence_diff", payload: %{"joins" => _, "leaves" => %{}}, topic: ^topic}

      # Wait for RateCounter to run
      Process.sleep(2000)

      # Expected billed
      # 2 joins due to two sockets
      # 7 presence events
      # 0 db events as no postgres changes used
      # 0 events as no broadcast used
      assert 2 = get_count([:realtime, :rate_counter, :channel, :joins], external_id)
      assert 7 = get_count([:realtime, :rate_counter, :channel, :presence_events], external_id)
      assert 0 = get_count([:realtime, :rate_counter, :channel, :db_events], external_id)
      assert 0 = get_count([:realtime, :rate_counter, :channel, :events], external_id)
    end

    test "postgres changes events", %{tenant: tenant} do
      external_id = tenant.external_id
      {socket, _} = get_connection(tenant)
      config = %{broadcast: %{self: true}, postgres_changes: [%{event: "*", schema: "public"}]}
      topic = "realtime:any"

      WebsocketClient.join(socket, topic, %{config: config})

      # Join events
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{topic: ^topic, event: "presence_state"}, 500
      assert_receive %Message{topic: ^topic, event: "system"}, 5000

      # Add second user to test the "multiplication" of billable events
      {socket, _} = get_connection(tenant)
      WebsocketClient.join(socket, topic, %{config: config})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{topic: ^topic, event: "presence_state"}, 500
      assert_receive %Message{topic: ^topic, event: "system"}, 5000

      tenant = Tenants.get_tenant_by_external_id(tenant.external_id)
      {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)

      # Postgres Change events
      for _ <- 1..5, do: Postgrex.query!(conn, "insert into test (details) values ('test')", [])

      for _ <- 1..5 do
        assert_receive %Message{
                         topic: ^topic,
                         event: "postgres_changes",
                         payload: %{"data" => %{"schema" => "public", "table" => "test", "type" => "INSERT"}}
                       },
                       5000
      end

      # Wait for RateCounter to run
      Process.sleep(2000)

      # Expected billed
      # 2 joins due to two sockets
      # 2 presence events due to two sockets
      # 10 db events due to 5 inserts events sent to client 1 and 5 inserts events sent to client 2
      # 0 events as no broadcast used
      assert 2 = get_count([:realtime, :rate_counter, :channel, :joins], external_id)
      assert 2 = get_count([:realtime, :rate_counter, :channel, :presence_events], external_id)
      # 5 + 5 + 5 (5 for each websocket and 5 while publishing)
      assert 15 = get_count([:realtime, :rate_counter, :channel, :db_events], external_id)
      assert 0 = get_count([:realtime, :rate_counter, :channel, :events], external_id)
    end

    test "postgres changes error events", %{tenant: tenant} do
      external_id = tenant.external_id
      {socket, _} = get_connection(tenant)
      config = %{broadcast: %{self: true}, postgres_changes: [%{event: "*", schema: "none"}]}
      topic = "realtime:any"

      WebsocketClient.join(socket, topic, %{config: config})

      # Join events
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{topic: ^topic, event: "presence_state"}, 500
      assert_receive %Message{topic: ^topic, event: "system"}, 5000

      # Wait for RateCounter to run
      Process.sleep(2000)

      # Expected billed
      # 1 joins due to one socket
      # 1 presence events due to one socket
      # 0 db events
      # 0 events as no broadcast used
      assert 1 = get_count([:realtime, :rate_counter, :channel, :joins], external_id)
      assert 1 = get_count([:realtime, :rate_counter, :channel, :presence_events], external_id)
      assert 0 = get_count([:realtime, :rate_counter, :channel, :db_events], external_id)
      assert 0 = get_count([:realtime, :rate_counter, :channel, :events], external_id)
    end
  end

  test "tracks and untracks properly channels", %{tenant: tenant} do
    assert [] = Tracker.list_pids()

    {socket, _} = get_connection(tenant)
    config = %{broadcast: %{self: true}, private: false, presence: %{enabled: false}}

    topics =
      for _ <- 1..10 do
        topic = "realtime:#{random_string()}"
        :ok = WebsocketClient.join(socket, topic, %{config: config})
        assert_receive %Message{topic: ^topic, event: "phx_reply"}, 500
        topic
      end

    assert [{_pid, count}] = Tracker.list_pids()
    assert count == length(topics)

    for topic <- topics do
      :ok = WebsocketClient.leave(socket, topic, %{})
      assert_receive %Message{topic: ^topic, event: "phx_close"}, 500
    end

    # wait to trigger tracker
    assert_process_down(socket, 5000)
    assert [] = Tracker.list_pids()
  end

  test "failed connections are present in tracker with counter counter lower than 0 so they are actioned on by tracker",
       %{tenant: tenant} do
    assert [] = Tracker.list_pids()

    {socket, _} = get_connection(tenant)
    config = %{broadcast: %{self: true}, private: true, presence: %{enabled: false}}

    for _ <- 1..10 do
      topic = "realtime:#{random_string()}"
      :ok = WebsocketClient.join(socket, topic, %{config: config})
      assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "error"}}, 500
    end

    assert [{_pid, count}] = Tracker.list_pids()
    assert count == 0
  end

  test "failed connections but one succeeds properly tracks",
       %{tenant: tenant} do
    assert [] = Tracker.list_pids()

    {socket, _} = get_connection(tenant)
    topic = "realtime:#{random_string()}"

    :ok =
      WebsocketClient.join(socket, topic, %{
        config: %{broadcast: %{self: true}, private: false, presence: %{enabled: false}}
      })

    assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}, 500
    assert [{_pid, count}] = Tracker.list_pids()
    assert count == 1

    for _ <- 1..10 do
      topic = "realtime:#{random_string()}"

      :ok =
        WebsocketClient.join(socket, topic, %{
          config: %{broadcast: %{self: true}, private: true, presence: %{enabled: false}}
        })

      assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "error"}}, 500
    end

    topic = "realtime:#{random_string()}"

    :ok =
      WebsocketClient.join(socket, topic, %{
        config: %{broadcast: %{self: true}, private: false, presence: %{enabled: false}}
      })

    assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}, 500
    assert [{_pid, count}] = Tracker.list_pids()
    assert count == 2
  end

  describe "WAL bloat handling" do
    setup %{tenant: tenant} do
      topic = random_string()
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)

      %{rows: [[max_wal_size]]} = Postgrex.query!(db_conn, "SHOW max_wal_size", [])
      %{rows: [[wal_keep_size]]} = Postgrex.query!(db_conn, "SHOW wal_keep_size", [])
      %{rows: [[max_slot_wal_keep_size]]} = Postgrex.query!(db_conn, "SHOW max_slot_wal_keep_size", [])

      assert max_wal_size == "32MB"
      assert wal_keep_size == "32MB"
      assert max_slot_wal_keep_size == "32MB"

      Postgrex.query!(db_conn, "CREATE TABLE IF NOT EXISTS wal_test (id INT, data TEXT)", [])

      Postgrex.query!(
        db_conn,
        """
          CREATE OR REPLACE FUNCTION wal_test_trigger_func() RETURNS TRIGGER AS $$
          BEGIN
            PERFORM realtime.send(json_build_object ('value', 'test' :: text)::jsonb, 'test', '#{topic}', false);
            RETURN NULL;
          END;
          $$ LANGUAGE plpgsql;
        """,
        []
      )

      Postgrex.query!(db_conn, "DROP TRIGGER IF EXISTS wal_test_trigger ON wal_test", [])

      Postgrex.query!(
        db_conn,
        """
          CREATE TRIGGER wal_test_trigger
          AFTER INSERT OR UPDATE OR DELETE ON wal_test
          FOR EACH ROW
          EXECUTE FUNCTION wal_test_trigger_func()
        """,
        []
      )

      GenServer.stop(db_conn)

      on_exit(fn ->
        {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)

        Postgrex.query!(db_conn, "DROP TABLE IF EXISTS wal_test CASCADE", [])
      end)

      %{topic: topic}
    end

    test "track PID changes during WAL bloat creation", %{tenant: tenant, topic: topic} do
      {socket, _} = get_connection(tenant, "authenticated")
      config = %{broadcast: %{self: true}, private: false}
      full_topic = "realtime:#{topic}"

      active_slot_query =
        "SELECT active_pid FROM pg_replication_slots where active_pid is not null and slot_name = 'supabase_realtime_messages_replication_slot_'"

      WebsocketClient.join(socket, full_topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500

      assert Connect.ready?(tenant.external_id)

      {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)

      original_connect_pid = Connect.whereis(tenant.external_id)
      original_replication_pid = ReplicationConnection.whereis(tenant.external_id)
      %{rows: [[original_db_pid]]} = Postgrex.query!(db_conn, active_slot_query, [])

      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            {:ok, bloat_conn} = Database.connect(tenant, "realtime_bloat", :stop)

            Postgrex.transaction(bloat_conn, fn conn ->
              Postgrex.query(conn, "INSERT INTO wal_test SELECT generate_series(1, 100000), repeat('x', 2000)", [])
              {:error, "test"}
            end)

            Process.exit(bloat_conn, :normal)
          end)
        end

      Task.await_many(tasks, 20000)

      # Kill all pending transactions still running
      Postgrex.query!(
        db_conn,
        "SELECT pg_terminate_backend(pid) from pg_stat_activity where application_name='realtime_bloat'",
        []
      )

      # Does it recover?
      assert Connect.ready?(tenant.external_id)
      {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      Process.sleep(1000)
      %{rows: [[new_db_pid]]} = Postgrex.query!(db_conn, active_slot_query, [])

      assert new_db_pid != original_db_pid
      assert ^original_connect_pid = Connect.whereis(tenant.external_id)
      assert original_replication_pid != ReplicationConnection.whereis(tenant.external_id)

      # Check if socket is still connected
      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, full_topic, "broadcast", payload)
      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^full_topic}, 500

      # Check if we are receiving the message from replication connection
      Postgrex.query!(db_conn, "INSERT INTO wal_test VALUES (1, 'test')", [])

      assert_receive %Phoenix.Socket.Message{
                       event: "broadcast",
                       payload: %{
                         "event" => "test",
                         "payload" => %{"value" => "test"},
                         "type" => "broadcast"
                       },
                       join_ref: nil,
                       ref: nil,
                       topic: ^full_topic
                     },
                     5000
    end
  end

  defp mode(%{mode: :distributed}) do
    tenant = Api.get_tenant_by_external_id("dev_tenant")

    RateCounter.stop(tenant.external_id)
    :ets.delete_all_objects(Tracker.table_name())

    Connect.shutdown(tenant.external_id)
    # Sleeping so that syn can forget about this Connect process
    Process.sleep(100)

    on_exit(fn ->
      Connect.shutdown(tenant.external_id)
      # Sleeping so that syn can forget about this Connect process
      Process.sleep(100)
    end)

    on_exit(fn -> Connect.shutdown(tenant.external_id) end)
    {:ok, node} = Clustered.start()
    region = Tenants.region(tenant)
    {:ok, db_conn} = :erpc.call(node, Connect, :connect, ["dev_tenant", region])
    assert Connect.ready?(tenant.external_id)

    assert node(db_conn) == node
    %{db_conn: db_conn, node: node, tenant: tenant}
  end

  defp mode(_) do
    tenant = Containers.checkout_tenant(run_migrations: true)
    RateCounter.stop(tenant.external_id)

    :ets.delete_all_objects(Tracker.table_name())
    Realtime.Tenants.Connect.shutdown(tenant.external_id)
    # Sleeping so that syn can forget about this Connect process
    Process.sleep(100)
    {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
    assert Connect.ready?(tenant.external_id)
    %{db_conn: db_conn, tenant: tenant}
  end

  defp rls_context(%{tenant: tenant} = context) do
    {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
    clean_table(db_conn, "realtime", "messages")
    topic = Map.get(context, :topic, random_string())
    policies = Map.get(context, :policies, nil)
    role = Map.get(context, :role, nil)
    sub = Map.get(context, :sub, nil)

    if policies, do: create_rls_policies(db_conn, policies, %{topic: topic, role: role, sub: sub})

    %{topic: topic, role: role, sub: sub}
  end

  defp setup_trigger(%{tenant: tenant, topic: topic}) do
    {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
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
    end)

    %{table_name: random_name}
  end

  defp change_tenant_configuration(%Tenant{external_id: external_id}, limit, value) do
    external_id
    |> Realtime.Tenants.get_tenant_by_external_id()
    |> Realtime.Api.Tenant.changeset(%{limit => value})
    |> Realtime.Repo.update!()

    Realtime.Tenants.Cache.invalidate_tenant_cache(external_id)
  end

  defp assert_process_down(pid, timeout \\ 300) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
  end
end
