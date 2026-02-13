defmodule Realtime.Integration.RtChannel.BroadcastTest do
  use RealtimeWeb.ConnCase,
    async: true,
    parameterize: [
      %{serializer: Phoenix.Socket.V1.JSONSerializer},
      %{serializer: RealtimeWeb.Socket.V2Serializer}
    ]

  import ExUnit.CaptureLog
  import Generators

  alias Phoenix.Socket.Message
  alias Postgrex
  alias Realtime.Database
  alias Realtime.Integration.WebsocketClient
  alias Realtime.Tenants.Connect

  @moduletag :capture_log

  setup [:checkout_tenant_and_connect]

  describe "public broadcast" do
    setup [:rls_context]

    test "public broadcast", %{tenant: tenant, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer)
      config = %{broadcast: %{self: true}, private: false}
      topic = "realtime:any"
      WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, topic, "broadcast", payload)

      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic}, 500
    end

    test "broadcast to another tenant does not get mixed up", %{tenant: tenant, serializer: serializer} do
      other_tenant = Containers.checkout_tenant(run_migrations: true)

      Realtime.Tenants.Cache.update_cache(other_tenant)

      {socket, _} = get_connection(tenant, serializer)
      config = %{broadcast: %{self: false}, private: false}
      topic = "realtime:any"
      WebsocketClient.join(socket, topic, %{config: config})

      {other_socket, _} = get_connection(other_tenant, serializer)
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

    @tag policies: []
    test "lack of connection to database error does not impact public channels", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer
    } do
      topic = "realtime:#{topic}"
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      WebsocketClient.join(socket, topic, %{config: %{broadcast: %{self: true}, private: false}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      {service_role_socket, _} = get_connection(tenant, serializer, role: "service_role")
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

  describe "private broadcast" do
    setup [:rls_context]

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "private broadcast with valid channel with permissions sends message", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
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
         topic: "topic"
    test "private broadcast with valid channel a colon character sends message and won't intercept in public channels",
         %{topic: topic, tenant: tenant, serializer: serializer} do
      {anon_socket, _} = get_connection(tenant, serializer, role: "anon")
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
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
      topic: topic,
      serializer: serializer
    } do
      config = %{broadcast: %{self: true}, private: true}
      topic = "realtime:#{topic}"

      {service_role_socket, _} = get_connection(tenant, serializer, role: "service_role")
      WebsocketClient.join(service_role_socket, topic, %{config: config})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
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
    test "private broadcast with valid channel and no read permissions won't join", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer
    } do
      config = %{private: true}
      expected = "Unauthorized: You do not have permissions to read from this Channel topic: #{topic}"

      topic = "realtime:#{topic}"
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")

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
    test "handles lack of connection to database error on private channels", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer
    } do
      topic = "realtime:#{topic}"
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      WebsocketClient.join(socket, topic, %{config: %{broadcast: %{self: true}, private: true}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 300
      assert_receive %Message{event: "presence_state"}

      {service_role_socket, _} = get_connection(tenant, serializer, role: "service_role")
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
  end

  describe "trigger-based broadcast changes" do
    setup [:rls_context, :setup_trigger]

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "broadcast insert event changes on insert in table with trigger", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn,
      table_name: table_name,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
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
      table_name: table_name,
      serializer: serializer
    } do
      value = random_string()
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
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
      table_name: table_name,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
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
      db_conn: db_conn,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
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
      db_conn: db_conn,
      serializer: serializer
    } do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
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
      {:ok, cleanup_conn} = Database.connect(tenant, "realtime_test", :stop)
      Postgrex.query!(cleanup_conn, "DROP TABLE #{random_name} CASCADE", [])
      GenServer.stop(cleanup_conn)
    end)

    %{table_name: random_name, db_conn: db_conn}
  end
end
