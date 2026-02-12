defmodule Realtime.Integration.RtChannel.WalBloatTest do
  use RealtimeWeb.ConnCase,
    async: false,
    parameterize: [
      %{serializer: Phoenix.Socket.V1.JSONSerializer},
      %{serializer: RealtimeWeb.Socket.V2Serializer}
    ]

  import Generators

  alias Phoenix.Socket.Message
  alias Postgrex
  alias Realtime.Database
  alias Realtime.Integration.WebsocketClient
  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.ReplicationConnection

  @moduletag :capture_log

  setup [:checkout_tenant_and_connect]

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
        GenServer.stop(db_conn)
      end)

      %{topic: topic}
    end

    @tag timeout: :timer.minutes(3)
    test "track PID changes during WAL bloat creation", %{tenant: tenant, topic: topic, serializer: serializer} do
      {socket, _} = get_connection(tenant, serializer, role: "authenticated")
      full_topic = "realtime:#{topic}"

      WebsocketClient.join(socket, full_topic, %{config: %{broadcast: %{self: true}, private: false}})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}}, 500
      assert_receive %Message{event: "presence_state"}, 500
      assert Connect.ready?(tenant.external_id)

      {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      original_connect_pid = Connect.whereis(tenant.external_id)
      original_replication_pid = ReplicationConnection.whereis(tenant.external_id)
      await_replication_slot_active(db_conn, 30, 500)
      original_db_pid = active_replication_slot_pid!(db_conn)

      replication_ref = Process.monitor(original_replication_pid)

      generate_wal_bloat(tenant)
      terminate_bloat_connections(db_conn)

      assert_receive {:DOWN, ^replication_ref, :process, ^original_replication_pid, _}, 60_000

      assert Connect.ready?(tenant.external_id)
      {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      new_db_pid = await_replication_slot_active(db_conn, 60, 1000)

      assert new_db_pid != original_db_pid
      assert ^original_connect_pid = Connect.whereis(tenant.external_id)
      assert original_replication_pid != ReplicationConnection.whereis(tenant.external_id)

      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      WebsocketClient.send_event(socket, full_topic, "broadcast", payload)
      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^full_topic}, 500

      Postgrex.query!(db_conn, "INSERT INTO wal_test VALUES (1, 'test')", [])

      assert_receive %Message{
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

  defp active_replication_slot_pid!(db_conn) do
    %{rows: [[pid]]} =
      Postgrex.query!(
        db_conn,
        "SELECT active_pid FROM pg_replication_slots WHERE active_pid IS NOT NULL AND slot_name = 'supabase_realtime_messages_replication_slot_'",
        []
      )

    pid
  end

  defp await_replication_slot_active(db_conn, retries, interval_ms) do
    Enum.reduce_while(1..retries, nil, fn _, _ ->
      case Postgrex.query!(
             db_conn,
             "SELECT active_pid FROM pg_replication_slots WHERE active_pid IS NOT NULL AND slot_name = 'supabase_realtime_messages_replication_slot_'",
             []
           ) do
        %{rows: [[pid]]} ->
          {:halt, pid}

        _ ->
          Process.sleep(interval_ms)
          {:cont, nil}
      end
    end)
    |> then(fn
      nil -> flunk("Replication slot did not become active within #{retries}s")
      pid -> pid
    end)
  end

  defp generate_wal_bloat(tenant) do
    1..5
    |> Enum.map(fn _ ->
      Task.async(fn ->
        {:ok, conn} = Database.connect(tenant, "realtime_bloat", :stop)

        Postgrex.transaction(conn, fn tx ->
          Postgrex.query(tx, "INSERT INTO wal_test SELECT generate_series(1, 100000), repeat('x', 2000)", [])
          {:error, "test"}
        end)

        Process.exit(conn, :normal)
      end)
    end)
    |> Task.await_many(20_000)
  end

  defp terminate_bloat_connections(db_conn) do
    Postgrex.query!(
      db_conn,
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'realtime_bloat'",
      []
    )
  end
end
