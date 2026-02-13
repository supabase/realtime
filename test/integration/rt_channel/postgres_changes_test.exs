defmodule Realtime.Integration.RtChannel.PostgresChangesTest do
  use RealtimeWeb.ConnCase,
    async: true,
    parameterize: [
      %{serializer: Phoenix.Socket.V1.JSONSerializer},
      %{serializer: RealtimeWeb.Socket.V2Serializer}
    ]

  import ExUnit.CaptureLog
  import Generators

  alias Extensions.PostgresCdcRls
  alias Phoenix.Socket.Message
  alias Postgrex
  alias Realtime.Database
  alias Realtime.Integration.WebsocketClient

  @moduletag :capture_log

  setup [:checkout_tenant_connect_and_setup_postgres_changes]

  describe "insert" do
    test "handle insert", %{tenant: tenant, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer)
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
  end

  describe "update" do
    test "handle update", %{tenant: tenant, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer)
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
  end

  describe "delete" do
    test "handle delete", %{tenant: tenant, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer)
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
  end

  describe "wildcard" do
    test "handle wildcard", %{tenant: tenant, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer)
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
  end

  describe "error handling" do
    test "error subscribing", %{tenant: tenant, serializer: serializer} do
      {:ok, conn} = Database.connect(tenant, "realtime_test")

      {:ok, _} =
        Database.transaction(conn, fn db_conn ->
          Postgrex.query!(db_conn, "drop publication if exists supabase_realtime_test")
        end)

      {socket, _} = get_connection(tenant, serializer)
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
                               "Unable to subscribe to changes with given parameters. Please check Realtime is enabled for the given connect parameters: [event: INSERT, schema: public, table: *, filters: []]",
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

    test "handle nil postgres changes params as empty param changes", %{tenant: tenant, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer)
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
end
