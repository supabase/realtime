defmodule Realtime.Tenants.ReplicationConnectionTest do
  # async: false due to the usage of mocks
  use Realtime.DataCase, async: false

  import ExUnit.CaptureLog
  import Mock

  alias Realtime.Api.Message
  alias Realtime.Tenants.ReplicationConnection
  alias Realtime.Database
  alias Realtime.Tenants.BatchBroadcast

  setup do
    slot = Application.get_env(:realtime, :slot_name_suffix)
    Application.put_env(:realtime, :slot_name_suffix, "test")

    tenant = Containers.checkout_tenant(true)

    on_exit(fn ->
      Application.put_env(:realtime, :slot_name_suffix, slot)
      Containers.checkin_tenant(tenant)
    end)

    %{tenant: tenant}
  end

  test "fails if tenant connection is invalid" do
    port = Enum.random(5500..9000)

    tenant =
      tenant_fixture(%{
        "extensions" => [
          %{
            "type" => "postgres_cdc_rls",
            "settings" => %{
              "db_host" => "127.0.0.1",
              "db_name" => "postgres",
              "db_user" => "supabase_admin",
              "db_password" => "postgres",
              "db_port" => "#{port}",
              "poll_interval" => 100,
              "poll_max_changes" => 100,
              "poll_max_record_bytes" => 1_048_576,
              "region" => "us-east-1",
              "ssl_enforced" => true
            }
          }
        ]
      })

    capture_log(fn ->
      assert {:error, _} = ReplicationConnection.start(tenant, self())
    end) =~ "UnableToStartHandler"
  end

  test "starts a handler for the tenant and broadcasts for single insert", %{tenant: tenant} do
    with_mock BatchBroadcast, broadcast: fn _, _, _, _ -> :ok end do
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
  end

  test "pid is associated to the same pid for a given tenant and guarantees uniqueness", %{tenant: tenant} do
    assert {:ok, pid} = ReplicationConnection.start(tenant, self())
    assert {:ok, ^pid} = ReplicationConnection.start(tenant, self())
  end

  test "fails on existing replication slot", %{tenant: tenant} do
    {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
    name = "supabase_realtime_messages_replication_slot_test"
    Postgrex.query!(db_conn, "SELECT pg_create_logical_replication_slot($1, 'test_decoding')", [name])

    assert {:error, "Temporary Replication slot already exists and in use"} =
             ReplicationConnection.start(tenant, self())
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
    test "returns pid if exists", %{tenant: tenant} do
      assert {:ok, pid} = ReplicationConnection.start(tenant, self())
      assert ReplicationConnection.whereis(tenant.external_id) == pid
    end

    test "returns nil if not exists" do
      assert ReplicationConnection.whereis(random_string()) == nil
    end
  end
end
