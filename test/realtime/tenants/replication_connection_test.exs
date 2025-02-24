defmodule Realtime.Tenants.ReplicationConnectionTest do
  # async: false due to the fact that we're using the database to intercept messages created which will interfer with other tests
  use Realtime.DataCase, async: false

  import ExUnit.CaptureLog
  import Mock

  alias Realtime.Api.Message
  alias Realtime.Tenants.ReplicationConnection
  alias Realtime.Database
  alias Realtime.Tenants.BatchBroadcast
  alias Realtime.Tenants.Migrations

  setup do
    Cleanup.ensure_no_replication_slot()
    slot = Application.get_env(:realtime, :slot_name_suffix)
    Application.put_env(:realtime, :slot_name_suffix, "test")
    start_supervised(Realtime.Tenants.CacheSupervisor)

    tenant = tenant_fixture()
    Migrations.run_migrations(tenant)

    {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)
    clean_table(conn, "realtime", "messages")

    publication =
      ReplicationConnection.publication_name(%ReplicationConnection{
        tenant_id: tenant.external_id,
        schema: "realtime",
        table: "messages"
      })

    Postgrex.query(conn, "DROP PUBLICATION #{publication}", [])

    on_exit(fn -> Application.put_env(:realtime, :slot_name_suffix, slot) end)

    %{tenant: tenant}
  end

  test "fails if tenant connection is invalid" do
    tenant =
      tenant_fixture(%{
        "extensions" => [
          %{
            "type" => "postgres_cdc_rls",
            "settings" => %{
              "db_host" => "localhost",
              "db_name" => "postgres",
              "db_user" => "supabase_admin",
              "db_password" => "bad",
              "db_port" => "5433",
              "poll_interval" => 100,
              "poll_max_changes" => 100,
              "poll_max_record_bytes" => 1_048_576,
              "region" => "us-east-1",
              "ssl_enforced" => false
            }
          }
        ]
      })

    capture_log(fn ->
      assert {:error, _} = ReplicationConnection.start(tenant, self())
    end) =~ "UnableToStartHandler"
  end

  test_with_mock "starts a handler for the tenant and broadcasts for single insert",
                 BatchBroadcast,
                 broadcast: fn _, _, _, _ -> :ok end do
    tenant = tenant_fixture()

    {:ok, _pid} = ReplicationConnection.start(tenant, self())

    total_messages = 5
    # Works with one insert per transaction
    for _ <- 1..total_messages do
      message_fixture(tenant, %{
        "topic" => random_string(),
        "private" => true,
        "event" => "INSERT",
        "payload" => %{"value" => random_string()}
      })
    end

    Process.sleep(500)

    assert_called_exactly(BatchBroadcast.broadcast(nil, tenant, :_, :_), total_messages)
    # Works with batch inserts
    messages =
      for _ <- 1..total_messages do
        Message.changeset(%Message{}, %{
          "topic" => random_string(),
          "private" => true,
          "event" => "INSERT",
          "payload" => %{"value" => random_string()}
        })
      end

    Database.connect(tenant, "realtime_test", :stop)
    Realtime.Repo.insert_all_entries(Message, messages, Message)
    Process.sleep(500)

    assert_called_exactly(BatchBroadcast.broadcast(nil, tenant, :_, :_), total_messages)
  end

  test "pid is associated to the same pid for a given tenant and guarantees uniqueness", %{tenant: tenant} do
    assert {:ok, pid} = ReplicationConnection.start(tenant, self())
    assert {:ok, ^pid} = ReplicationConnection.start(tenant, self())
  end

  test "fails on existing replication slot" do
    # Warning: this will only work in testing environments as we are using the same database instance but different tenants so the replication slot will be shared
    tenant1 = tenant_fixture()
    tenant2 = tenant_fixture()

    assert {:ok, _pid} = ReplicationConnection.start(tenant1, self())

    assert {:error, "Temporary Replication slot already exists and in use"} =
             ReplicationConnection.start(tenant2, self())
  end

  defmodule TestHandler do
    @behaviour PostgresReplication.Handler
    import PostgresReplication.Protocol
    alias PostgresReplication.Protocol.KeepAlive

    @impl true
    def call(message, _metadata) when is_write(message) do
      :noreply
    end

    def call(message, _metadata) when is_keep_alive(message) do
      reply =
        case parse(message) do
          %KeepAlive{reply: :now, wal_end: wal_end} ->
            wal_end = wal_end + 1
            standby(wal_end, wal_end, wal_end, :now)

          _ ->
            hold()
        end

      {:reply, reply}
    end

    def call(_, _), do: :noreply
  end

  test "handle standby connections exceeds max_wal_senders", %{tenant: tenant} do
    opts = Database.from_tenant(tenant, "realtime_test", :stop) |> Database.opts()

    # This creates a loop of errors that occupies all WAL senders and lets us test the error handling
    pids =
      for i <- 0..4 do
        replication_slot_opts =
          %PostgresReplication{
            connection_opts: opts,
            table: :all,
            output_plugin: "pgoutput",
            output_plugin_options: [],
            handler_module: TestHandler,
            publication_name: "test_#{i}_publication",
            replication_slot_name: "test_#{i}_slot"
          }

        {:ok, pid} = PostgresReplication.start_link(replication_slot_opts)
        pid
      end

    on_exit(fn ->
      Enum.each(pids, &Process.exit(&1, :kill))
      Process.sleep(2000)
    end)

    assert {:error, :max_wal_senders_reached} = ReplicationConnection.start(tenant, self())
  end

  describe "whereis/1" do
    test "returns pid if exists" do
      tenant = tenant_fixture()
      assert {:ok, pid} = ReplicationConnection.start(tenant, self())
      assert ReplicationConnection.whereis(tenant.external_id) == pid
    end

    test "returns nil if not exists" do
      assert ReplicationConnection.whereis(random_string()) == nil
    end
  end
end
