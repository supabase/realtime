defmodule Realtime.Tenants.ConnectTest do
  # async: false due to the fact that we are checking ets tables for user tracking and usage of mocks
  use Realtime.DataCase, async: false
  import ExUnit.CaptureLog
  import Mock
  import ExUnit.CaptureLog

  alias Realtime.Database
  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Listen
  alias Realtime.Tenants.ReplicationConnection
  alias Realtime.UsersCounter

  setup do
    :ets.delete_all_objects(Connect)

    tenant = tenant_fixture()
    tenant = Containers.initialize(tenant, true, true)
    on_exit(fn -> Containers.stop_container(tenant) end)

    %{tenant: tenant}
  end

  describe "lookup_or_start_connection/1" do
    test "if tenant exists and connected, returns the db connection and tracks it in ets", %{tenant: tenant} do
      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      Process.sleep(500)
      assert is_pid(db_conn)
      assert Connect.shutdown(tenant.external_id) == :ok
    end

    test "tracks multiple users that connect and disconnect" do
      expected =
        for _ <- 1..2 do
          tenant = tenant_fixture()
          tenant = Containers.initialize(tenant, true, true)
          on_exit(fn -> Containers.stop_container(tenant) end)

          assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
          Process.sleep(500)

          assert is_pid(db_conn)
          Connect.shutdown(tenant.external_id)

          tenant.external_id
        end

      result = :ets.select(Connect, [{{:"$1"}, [], [:"$1"]}]) |> Enum.sort()
      expected = Enum.sort(expected)
      assert result == expected
    end

    test "on database disconnect, returns new connection", %{tenant: tenant} do
      assert {:ok, old_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      Process.sleep(1000)
      Connect.shutdown(tenant.external_id)
      Process.sleep(1000)

      assert {:ok, new_conn} = Connect.lookup_or_start_connection(tenant.external_id)

      on_exit(fn -> Process.exit(new_conn, :shutdown) end)

      assert new_conn != old_conn
      Connect.shutdown(tenant.external_id)
    end

    test "if tenant exists but unable to connect, returns error" do
      port = Enum.random(5500..9000)

      extensions = [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
            "db_name" => "postgres",
            "db_user" => "postgres",
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

      tenant = tenant_fixture(%{extensions: extensions})

      assert {:error, :tenant_database_unavailable} =
               Connect.lookup_or_start_connection(tenant.external_id)
    end

    test "if tenant does not exist, returns error" do
      assert {:error, :tenant_not_found} = Connect.lookup_or_start_connection("none")
    end

    test "if no users are connected to a tenant channel, stop the connection", %{tenant: %{external_id: tenant_id}} do
      {:ok, db_conn} =
        Connect.lookup_or_start_connection(tenant_id, check_connected_user_interval: 100)

      # Not enough time has passed, connection still alive
      Process.sleep(400)
      assert {_, %{conn: _}} = :syn.lookup(Connect, tenant_id)

      # Enough time has passed, connection stopped
      Process.sleep(1000)
      assert :undefined = :syn.lookup(Connect, tenant_id)
      refute Process.alive?(db_conn)
      Connect.shutdown(tenant_id)
    end

    test "if users are connected to a tenant channel, keep the connection", %{tenant: %{external_id: tenant_id}} do
      UsersCounter.add(self(), tenant_id)

      {:ok, db_conn} =
        Connect.lookup_or_start_connection(tenant_id, check_connected_user_interval: 10)

      # Emulate connected user
      UsersCounter.add(self(), tenant_id)
      assert {pid, %{conn: conn_pid}} = :syn.lookup(Connect, tenant_id)
      Process.sleep(300)
      assert {^pid, %{conn: ^conn_pid}} = :syn.lookup(Connect, tenant_id)
      assert Process.alive?(db_conn)

      Connect.shutdown(tenant_id)
    end

    test "connection is killed after user leaving" do
      tenant = tenant_fixture()
      %{external_id: external_id} = Containers.initialize(tenant, true, true)
      on_exit(fn -> Containers.stop_container(tenant) end)

      UsersCounter.add(self(), external_id)

      {:ok, db_conn} = Connect.lookup_or_start_connection(external_id, check_connected_user_interval: 10)

      assert {_pid, %{conn: ^db_conn}} = :syn.lookup(Connect, external_id)
      Process.sleep(1000)
      :syn.leave(:users, external_id, self())
      Process.sleep(1000)
      assert :undefined = :syn.lookup(Connect, external_id)
      refute Process.alive?(db_conn)
      Connect.shutdown(external_id)
    end

    test "error if tenant is suspended" do
      tenant = tenant_fixture(suspend: true)
      assert {:error, :tenant_suspended} = Connect.lookup_or_start_connection(tenant.external_id)
    end

    test "handles tenant suspension and unsuspension in a reactive way" do
      tenant = tenant_fixture()
      tenant = Containers.initialize(tenant, true, true)
      on_exit(fn -> Containers.stop_container(tenant) end)
      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      Process.sleep(500)

      Realtime.Tenants.suspend_tenant_by_external_id(tenant.external_id)
      Process.sleep(500)

      assert {:error, :tenant_suspended} = Connect.lookup_or_start_connection(tenant.external_id)
      assert Process.alive?(db_conn) == false

      Realtime.Tenants.unsuspend_tenant_by_external_id(tenant.external_id)
      Process.sleep(50)
      assert {:ok, _} = Connect.lookup_or_start_connection(tenant.external_id)
      Connect.shutdown(tenant.external_id)
    end

    test "handles tenant suspension only on targetted suspended user" do
      tenant1 = Containers.checkout_tenant(true)
      tenant2 = Containers.checkout_tenant(true)

      on_exit(fn ->
        Containers.checkin_tenant(tenant1)
        Containers.checkin_tenant(tenant2)
      end)

      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant1.external_id)
      Process.sleep(1000)

      log =
        capture_log(fn ->
          Realtime.Tenants.suspend_tenant_by_external_id(tenant2.external_id)
          Process.sleep(100)
        end)

      refute log =~ "Tenant was suspended"
      assert Process.alive?(db_conn)
    end

    test "properly handles of failing calls by avoid creating too many connections" do
      port = Enum.random(5500..6000)

      tenant =
        tenant_fixture(%{
          extensions: [
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

      tenant = Containers.initialize(tenant, true)

      Enum.each(1..10, fn _ ->
        Task.start(fn ->
          Connect.lookup_or_start_connection(tenant.external_id)
        end)
      end)

      send(check_db_connections_created(self(), tenant.external_id), :check)
      Process.sleep(5000)
      refute_receive :too_many_connections
    end

    test "on migrations failure, stop the process", %{tenant: tenant} do
      with_mock Realtime.Tenants.Migrations, [], run_migrations: fn _ -> raise("error") end do
        assert {:ok, pid} = Connect.lookup_or_start_connection(tenant.external_id)
        Process.sleep(1000)
        refute Process.alive?(pid)
        assert_called(Realtime.Tenants.Migrations.run_migrations(tenant))
      end
    end

    test "starts broadcast handler and does not fail on existing connection", %{tenant: tenant} do
      assert {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      Process.sleep(3000)

      replication_connection_before = ReplicationConnection.whereis(tenant.external_id)
      listen_before = Listen.whereis(tenant.external_id)

      assert Process.alive?(replication_connection_before)
      assert Process.alive?(listen_before)

      assert {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)

      replication_connection_after = ReplicationConnection.whereis(tenant.external_id)
      listen_after = Listen.whereis(tenant.external_id)
      assert Process.alive?(replication_connection_after)
      assert Process.alive?(listen_after)

      assert replication_connection_before == replication_connection_after
      assert listen_before == listen_after
    end

    test "on replication connection postgres pid being stopped, also kills the Connect module", %{tenant: tenant} do
      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      Process.sleep(500)

      replication_connection_pid = ReplicationConnection.whereis(tenant.external_id)
      assert Process.alive?(replication_connection_pid)
      pid = Connect.whereis(tenant.external_id)

      Postgrex.query!(
        db_conn,
        "SELECT pg_terminate_backend(pid) from pg_stat_activity where application_name='realtime_replication_connection'",
        []
      )

      Process.sleep(500)

      refute Process.alive?(replication_connection_pid)
      refute Process.alive?(pid)
    end

    test "on replication connection exit, also kills the Connect module", %{tenant: tenant} do
      assert {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      Process.sleep(500)

      replication_connection_pid = ReplicationConnection.whereis(tenant.external_id)
      assert Process.alive?(replication_connection_pid)
      pid = Connect.whereis(tenant.external_id)
      Process.exit(replication_connection_pid, :kill)
      Process.sleep(500)

      refute Process.alive?(replication_connection_pid)
      refute Process.alive?(pid)
    end

    test "on listen exit, also kills the Connect module", %{tenant: tenant} do
      assert {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      Process.sleep(500)

      listen_pid = ReplicationConnection.whereis(tenant.external_id)
      assert Process.alive?(listen_pid)

      pid = Connect.whereis(tenant.external_id)
      Process.exit(listen_pid, :kill)
      Process.sleep(500)

      refute Process.alive?(listen_pid)
      refute Process.alive?(pid)
    end

    test "handles max_wal_senders by logging the correct operational code" do
      tenant = tenant_fixture()
      tenant = Containers.initialize(tenant, true, true)
      on_exit(fn -> Containers.stop_container(tenant) end)

      opts = tenant |> Database.from_tenant("realtime_test", :stop) |> Database.opts()

      # This creates a loop of errors that occupies all WAL senders and lets us test the error handling
      pids =
        for i <- 0..10 do
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
        Enum.each(pids, &Process.exit(&1, :normal))
        Process.sleep(2000)
      end)

      log =
        capture_log(fn ->
          assert {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
          Process.sleep(3000)
        end)

      assert log =~ "ReplicationMaxWalSendersReached"
    end

    test "syn with no connection", %{tenant: tenant} do
      with_mock :syn, [], lookup: fn _, _ -> {nil, %{conn: nil}} end do
        assert {:error, :tenant_database_unavailable} =
                 Connect.lookup_or_start_connection(tenant.external_id)

        assert {:error, :initializing} =
                 Connect.get_status(tenant.external_id)
      end
    end

    test "handle rpc errors gracefully" do
      with_mock Realtime.Nodes, get_node_for_tenant: fn _ -> {:ok, :potato@nohost} end do
        assert {:error, :rpc_error, _} = Connect.lookup_or_start_connection("tenant")
      end
    end
  end

  describe "shutdown/1" do
    test "shutdowns all associated connections", %{tenant: tenant} do
      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      assert Process.alive?(db_conn)
      Process.sleep(1000)
      assert Process.alive?(Connect.whereis(tenant.external_id))
      assert Process.alive?(ReplicationConnection.whereis(tenant.external_id))
      assert Process.alive?(Listen.whereis(tenant.external_id))

      Connect.shutdown(tenant.external_id)
      Process.sleep(1000)
      refute Connect.whereis(tenant.external_id)
      refute ReplicationConnection.whereis(tenant.external_id)
      refute Listen.whereis(tenant.external_id)
    end

    test "if tenant does not exist, does nothing" do
      assert :ok = Connect.shutdown("none")
    end

    test "tenant not able to connect if database has not enough connections" do
      port = Enum.random(5500..9000)

      extensions = [
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
            "ssl_enforced" => false,
            "db_pool" => 100,
            "subcriber_pool_size" => 100,
            "subs_pool_size" => 100
          }
        }
      ]

      tenant = tenant_fixture(%{extensions: extensions})
      tenant = Containers.initialize(tenant, true)
      on_exit(fn -> Containers.stop_container(tenant) end)

      assert {:error, :tenant_db_too_many_connections} =
               Connect.lookup_or_start_connection(tenant.external_id)
    end
  end

  defp check_db_connections_created(test_pid, tenant_id) do
    spawn(fn ->
      receive do
        :check ->
          processes =
            for pid <- Process.list(),
                info = Process.info(pid),
                dict = Keyword.get(info, :dictionary, []),
                match?({DBConnection.Connection, :init, 1}, dict[:"$initial_call"]),
                Keyword.get(dict, :"$logger_metadata$")[:external_id] == tenant_id do
              pid
            end

          Process.send_after(check_db_connections_created(test_pid, tenant_id), :check, 500)

          if length(processes) > 1 do
            send(test_pid, :too_many_connections)
          end
      end
    end)
  end
end
