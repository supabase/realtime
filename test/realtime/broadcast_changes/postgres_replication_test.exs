defmodule Realtime.BroadcastChanges.PostgresReplicationTest do
  # async: false due to usage of tenant database
  use Realtime.DataCase, async: false

  import Realtime.Adapters.Postgres.Decoder
  import Realtime.Adapters.Postgres.Protocol

  alias Realtime.BroadcastChanges.PostgresReplication
  alias Realtime.Database
  alias Realtime.Tenants.Migrations

  defmodule Handler do
    @behaviour PostgresReplication.Handler
    def call(message, %{pid: pid}) when is_write(message) do
      %{message: message} = parse(message)

      message
      |> decode_message()
      |> then(&send(pid, &1))

      :noreply
    end

    def call(message, _) when is_keep_alive(message) do
      %{reply: reply, wal_end: wal_end} = parse(message)
      wal_end = wal_end + 1

      message =
        case reply do
          :now -> standby_status(wal_end, wal_end, wal_end, reply)
          :later -> hold()
        end

      {:reply, message}
    end
  end

  describe "able to connect sucessfully" do
    setup do
      tenant = tenant_fixture()
      connection_opts = Database.from_tenant(tenant, "realtime_broadcast_changes", :stop, true)

      config = %PostgresReplication{
        connection_opts: [
          hostname: connection_opts.host,
          username: connection_opts.user,
          password: connection_opts.pass,
          database: connection_opts.name,
          port: connection_opts.port
        ],
        schema: "realtime",
        table: "messages",
        handler_module: __MODULE__.Handler,
        metadata: %{pid: self()}
      }

      tenant = tenant_fixture()
      [%{settings: settings} | _] = tenant.extensions
      migrations = %Migrations{tenant_external_id: tenant.external_id, settings: settings}
      Migrations.run_migrations(migrations)
      {:ok, conn} = Database.connect(tenant, "realtime_test", 1)
      clean_table(conn, "realtime", "messages")
      Postgrex.query(conn, "DROP PUBLICATION IF EXISTS realtime_messages_publication", [])
      Realtime.Database.replication_slot_teardown(tenant)

      {:ok, %{tenant: tenant, config: config}}
    end

    test "handles messages for the given replicated table", %{tenant: tenant, config: config} do
      start_supervised!({PostgresReplication, config})

      # Emit message to be captured by Handler
      message_fixture(tenant)
      assert_receive %Realtime.Adapters.Postgres.Decoder.Messages.Begin{}
      assert_receive %Realtime.Adapters.Postgres.Decoder.Messages.Relation{}
      assert_receive %Realtime.Adapters.Postgres.Decoder.Messages.Insert{}
      assert_receive %Realtime.Adapters.Postgres.Decoder.Messages.Commit{}
    end
  end

  describe "unable to connect sucessfully" do
    test "process does not start" do
      config = %PostgresReplication{
        connection_opts: [
          hostname: "localhost",
          username: "bad",
          password: "bad",
          database: "bad"
        ],
        schema: "realtime",
        table: "messages",
        handler_module: __MODULE__.Handler,
        metadata: %{pid: self()}
      }

      result = start_supervised({PostgresReplication, config})
      assert {:error, _} = result
    end
  end
end
