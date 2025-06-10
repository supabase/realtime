defmodule Realtime.Tenants.ConnectTest do
  # Async false due to Mimic running as global because we are spawning Connect processes
  use Realtime.DataCase, async: false
  use Mimic

  setup :set_mimic_global

  import ExUnit.CaptureLog

  alias Realtime.Database
  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Listen
  alias Realtime.Tenants.ReplicationConnection
  alias Realtime.UsersCounter

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)

    %{tenant: tenant}
  end

  defp assert_process_down(pid, timeout \\ 100) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
  end

  describe "lookup_or_start_connection/1" do
    test "if tenant exists and connected, returns the db connection and tracks it in ets", %{tenant: tenant} do
      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      assert is_pid(db_conn)
      assert Connect.shutdown(tenant.external_id) == :ok
    end

    test "tracks multiple users that connect and disconnect", %{tenant: tenant1} do
      tenant2 = Containers.checkout_tenant(run_migrations: true)
      tenants = [tenant1, tenant2]

      for tenant <- tenants do
        assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)

        assert is_pid(db_conn)
        Connect.shutdown(tenant.external_id)
        assert_process_down(db_conn)

        tenant.external_id
      end

      result = :ets.select(Connect, [{{:"$1"}, [], [:"$1"]}]) |> Enum.sort()
      assert tenant1.external_id in result
      assert tenant2.external_id in result
    end

    test "on database disconnect, returns new connection", %{tenant: tenant} do
      assert {:ok, old_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      Connect.shutdown(tenant.external_id)
      assert_process_down(old_conn)
      # Sleeping here so that syn has enough time to unregister
      # This could be avoided if we called :syn.unregister/2 on shutdown
      Process.sleep(100)

      assert {:ok, new_conn} = Connect.lookup_or_start_connection(tenant.external_id)

      on_exit(fn -> Process.exit(new_conn, :shutdown) end)

      assert new_conn != old_conn
      Connect.shutdown(tenant.external_id)
    end

    test "if tenant exists but unable to connect, returns error" do
      port = Generators.port()

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
      external_id = tenant.external_id

      assert capture_log(fn ->
               assert {:error, :tenant_database_unavailable} =
                        Connect.lookup_or_start_connection(tenant.external_id)
             end) =~ "project=#{external_id} external_id=#{external_id} [error] UnableToConnectToTenantDatabase"
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

      assert_process_down(db_conn, 1000)
      # Enough time has passed, syn has cleaned up
      Process.sleep(100)
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

    test "connection is killed after user leaving", %{tenant: tenant} do
      external_id = tenant.external_id
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

    test "handles tenant suspension and unsuspension in a reactive way", %{tenant: tenant} do
      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      assert Connect.ready?(tenant.external_id)

      Realtime.Tenants.suspend_tenant_by_external_id(tenant.external_id)
      assert_process_down(db_conn)
      # Wait for syn to unregister and Cachex to be invalided
      Process.sleep(100)

      assert {:error, :tenant_suspended} = Connect.lookup_or_start_connection(tenant.external_id)
      refute Process.alive?(db_conn)

      Realtime.Tenants.unsuspend_tenant_by_external_id(tenant.external_id)
      Process.sleep(50)
      assert {:ok, _} = Connect.lookup_or_start_connection(tenant.external_id)
      Connect.shutdown(tenant.external_id)
    end

    test "handles tenant suspension only on targetted suspended user", %{tenant: tenant1} do
      tenant2 = Containers.checkout_tenant(run_migrations: true)

      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant1.external_id)

      log =
        capture_log(fn ->
          Realtime.Tenants.suspend_tenant_by_external_id(tenant2.external_id)
          Process.sleep(50)
        end)

      refute log =~ "Tenant was suspended"
      assert Process.alive?(db_conn)
    end

    test "properly handles of failing calls by avoid creating too many connections", %{tenant: tenant} do
      extension = %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "db_host" => "127.0.0.1",
          "db_name" => "postgres",
          "db_user" => "supabase_admin",
          "db_password" => "postgres",
          "poll_interval" => 100,
          "poll_max_changes" => 100,
          "poll_max_record_bytes" => 1_048_576,
          "region" => "us-east-1",
          "ssl_enforced" => true
        }
      }

      {:ok, tenant} = update_extension(tenant, extension)

      Enum.each(1..10, fn _ ->
        Task.start(fn ->
          Connect.lookup_or_start_connection(tenant.external_id)
        end)
      end)

      send(check_db_connections_created(self(), tenant.external_id), :check)
      Process.sleep(5000)
      refute_receive :too_many_connections
    end

    test "on migrations failure, stop the process" do
      tenant = Containers.checkout_tenant(run_migrations: false)
      expect(Realtime.Tenants.Migrations, :run_migrations, fn ^tenant -> raise "error" end)

      assert {:ok, pid} = Connect.lookup_or_start_connection(tenant.external_id)
      assert_process_down(pid)
      refute Process.alive?(pid)
    end

    test "starts broadcast handler and does not fail on existing connection", %{tenant: tenant} do
      assert {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      assert Connect.ready?(tenant.external_id)

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
      assert Connect.ready?(tenant.external_id)

      replication_connection_pid = ReplicationConnection.whereis(tenant.external_id)
      assert Process.alive?(replication_connection_pid)
      pid = Connect.whereis(tenant.external_id)

      Postgrex.query!(
        db_conn,
        "SELECT pg_terminate_backend(pid) from pg_stat_activity where application_name='realtime_replication_connection'",
        []
      )

      assert_process_down(replication_connection_pid)
      assert_process_down(pid)
    end

    test "on replication connection exit, also kills the Connect module", %{tenant: tenant} do
      assert {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      assert Connect.ready?(tenant.external_id)

      replication_connection_pid = ReplicationConnection.whereis(tenant.external_id)
      assert Process.alive?(replication_connection_pid)
      pid = Connect.whereis(tenant.external_id)
      Process.exit(replication_connection_pid, :kill)

      assert_process_down(replication_connection_pid)
      assert_process_down(pid)
    end

    test "on listen exit, also kills the Connect module", %{tenant: tenant} do
      assert {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      assert Connect.ready?(tenant.external_id)

      listen_pid = Listen.whereis(tenant.external_id)
      assert Process.alive?(listen_pid)

      pid = Connect.whereis(tenant.external_id)
      Process.exit(listen_pid, :kill)

      assert_process_down(listen_pid)
      assert_process_down(pid)
      refute Process.alive?(listen_pid)
      refute Process.alive?(pid)
    end

    test "handles max_wal_senders by logging the correct operational code", %{tenant: tenant} do
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
      end)

      log =
        capture_log(fn ->
          assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
          assert_process_down(db_conn)
        end)

      assert log =~ "ReplicationMaxWalSendersReached"
    end

    test "syn with no connection", %{tenant: tenant} do
      external_id = tenant.external_id
      expect(:syn, :lookup, 2, fn Connect, ^external_id -> {nil, %{conn: nil}} end)

      assert {:error, :tenant_database_unavailable} = Connect.lookup_or_start_connection(external_id)
      assert {:error, :initializing} = Connect.get_status(external_id)
    end

    test "handle rpc errors gracefully" do
      expect(Realtime.Nodes, :get_node_for_tenant, fn _ -> {:ok, :potato@nohost} end)

      assert capture_log(fn -> assert {:error, :rpc_error, _} = Connect.lookup_or_start_connection("tenant") end) =~
               "project=tenant external_id=tenant [error] ErrorOnRpcCall"
    end
  end

  describe "connect/1" do
    test "respects backoff pipe", %{tenant: tenant} do
      external_id = tenant.external_id

      log =
        capture_log(fn ->
          for _ <- 1..10 do
            Connect.connect(external_id)
            Process.sleep(10)
            Connect.shutdown(external_id)
          end

          assert {:error, :tenant_create_backoff} = Connect.connect(external_id)
        end)

      assert log =~ "Too many connect attempts to tenant database"
      assert log =~ "project=#{external_id} external_id=#{external_id} [warning] TooManyConnectAttempts"
    end

    test "after timer, is able to connect", %{tenant: tenant} do
      external_id = tenant.external_id

      for _ <- 1..10 do
        Connect.connect(external_id)
        Process.sleep(10)
        Connect.shutdown(external_id)
      end

      assert {:error, :tenant_create_backoff} = Connect.connect(external_id)

      Process.sleep(5000)
      assert {:ok, _pid} = Connect.connect(external_id)
    end
  end

  describe "shutdown/1" do
    test "shutdowns all associated connections", %{tenant: tenant} do
      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      assert Process.alive?(db_conn)
      assert Connect.ready?(tenant.external_id)
      connect_pid = Connect.whereis(tenant.external_id)
      replication_connection_pid = ReplicationConnection.whereis(tenant.external_id)
      listen_pid = Listen.whereis(tenant.external_id)
      assert Process.alive?(connect_pid)
      assert Process.alive?(replication_connection_pid)
      assert Process.alive?(listen_pid)

      Connect.shutdown(tenant.external_id)
      assert_process_down(connect_pid)
      assert_process_down(replication_connection_pid)
      assert_process_down(listen_pid)
    end

    test "if tenant does not exist, does nothing" do
      assert :ok = Connect.shutdown("none")
    end

    test "tenant not able to connect if database has not enough connections", %{tenant: tenant} do
      extension = %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "db_host" => "127.0.0.1",
          "db_name" => "postgres",
          "db_user" => "supabase_admin",
          "db_password" => "postgres",
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

      {:ok, tenant} = update_extension(tenant, extension)

      assert {:error, :tenant_db_too_many_connections} =
               Connect.lookup_or_start_connection(tenant.external_id)
    end
  end

  describe "registers into local registry" do
    test "successfully registers a process", %{tenant: %{external_id: external_id}} do
      assert {:ok, _db_conn} = Connect.lookup_or_start_connection(external_id)
      assert Registry.whereis_name({Realtime.Tenants.Connect.Registry, external_id})
    end

    test "successfully unregisters a process", %{tenant: %{external_id: external_id}} do
      assert {:ok, _db_conn} = Connect.lookup_or_start_connection(external_id)
      assert Registry.whereis_name({Realtime.Tenants.Connect.Registry, external_id})
      Connect.shutdown(external_id)
      Process.sleep(100)
      assert :undefined = Registry.whereis_name({Realtime.Tenants.Connect.Registry, external_id})
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

  defp update_extension(tenant, extension) do
    db_port = Realtime.Crypto.decrypt!(hd(tenant.extensions).settings["db_port"])

    extensions = [
      put_in(extension, ["settings", "db_port"], db_port)
    ]

    Realtime.Api.update_tenant(tenant, %{extensions: extensions})
  end
end
