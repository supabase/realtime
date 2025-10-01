defmodule Realtime.Tenants.ConnectTest do
  # Async false due to Mimic running as global because we are spawning Connect processes
  use Realtime.DataCase, async: false
  use Mimic

  setup :set_mimic_global

  import ExUnit.CaptureLog

  alias Realtime.Database
  alias Realtime.Tenants
  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Rebalancer
  alias Realtime.Tenants.ReplicationConnection
  alias Realtime.UsersCounter

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)

    %{tenant: tenant}
  end

  defp assert_process_down(pid, timeout \\ 100, reason \\ nil) do
    ref = Process.monitor(pid)

    if reason do
      assert_receive {:DOWN, ^ref, :process, ^pid, ^reason}, timeout
    else
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
    end
  end

  defp refute_process_down(pid, timeout \\ 500) do
    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
  end

  describe "temporary process" do
    test "starts a temporary process", %{tenant: tenant} do
      assert {:ok, _} = Connect.lookup_or_start_connection(tenant.external_id)
      pid = Connect.whereis(tenant.external_id)
      # Brutally kill the process
      Process.exit(pid, :kill)
      assert_process_down(pid)
      # Wait to ensure that the process has not restarted
      Process.sleep(1000)

      # Temporary process should not be registered in syn
      refute Connect.whereis(tenant.external_id)
    end
  end

  describe "handle cold start" do
    test "multiple processes connecting calling Connect.connect", %{tenant: tenant} do
      parent = self()

      # Let's slow down Connect.connect so that multiple RPC calls are executed
      stub(Connect, :connect, fn x, y, z ->
        :timer.sleep(1000)
        call_original(Connect, :connect, [x, y, z])
      end)

      connect = fn -> send(parent, Connect.lookup_or_start_connection(tenant.external_id)) end
      # Let's call enough times to potentially trigger the Connect RateCounter

      for _ <- 1..50, do: spawn(connect)

      assert_receive({:ok, pid}, 1100)

      for _ <- 1..49, do: assert_receive({:ok, ^pid})

      # Does not trigger rate limit as connections eventually succeeded

      {:ok, rate_counter} =
        tenant.external_id
        |> Tenants.connect_errors_per_second_rate()
        |> Realtime.RateCounter.get()

      assert rate_counter.sum == 0
      assert rate_counter.avg == 0.0
      assert rate_counter.limit.triggered == false
    end

    test "multiple proccesses succeed together", %{tenant: tenant} do
      parent = self()

      # Let's slow down Connect starting
      expect(Database, :check_tenant_connection, fn t ->
        :timer.sleep(1000)
        call_original(Database, :check_tenant_connection, [t])
      end)

      connect = fn -> send(parent, Connect.lookup_or_start_connection(tenant.external_id)) end

      # Start an early connect
      spawn(connect)
      :timer.sleep(100)

      # Start others
      spawn(connect)
      spawn(connect)

      # This one should block and wait for the first Connect
      {:ok, pid} = Connect.lookup_or_start_connection(tenant.external_id)

      assert_receive {:ok, ^pid}
      assert_receive {:ok, ^pid}
      assert_receive {:ok, ^pid}
    end

    test "more than 15 seconds passed error out", %{tenant: tenant} do
      parent = self()

      # Let's slow down Connect starting
      expect(Database, :check_tenant_connection, fn t ->
        Process.sleep(15500)
        call_original(Database, :check_tenant_connection, [t])
      end)

      connect = fn -> send(parent, Connect.lookup_or_start_connection(tenant.external_id)) end

      spawn(connect)
      spawn(connect)

      {:error, :initializing} = Connect.lookup_or_start_connection(tenant.external_id)
      # The above call waited 15 seconds
      assert_receive {:error, :initializing}
      assert_receive {:error, :initializing}

      # This one will succeed
      {:ok, _pid} = Connect.lookup_or_start_connection(tenant.external_id)
    end

    test "too many db connections", %{tenant: tenant} do
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

      parent = self()

      # Let's slow down Connect starting
      expect(Database, :check_tenant_connection, fn t ->
        :timer.sleep(1000)
        call_original(Database, :check_tenant_connection, [t])
      end)

      connect = fn -> send(parent, Connect.lookup_or_start_connection(tenant.external_id)) end

      # Start an early connect
      spawn(connect)
      :timer.sleep(100)

      # Start others
      spawn(connect)
      spawn(connect)

      # This one should block and wait for the first Connect
      {:error, :tenant_db_too_many_connections} = Connect.lookup_or_start_connection(tenant.external_id)

      assert_receive {:error, :tenant_db_too_many_connections}
      assert_receive {:error, :tenant_db_too_many_connections}
      assert_receive {:error, :tenant_db_too_many_connections}
      refute_receive _any
    end
  end

  describe "region rebalancing" do
    test "rebalancing needed process stops", %{tenant: tenant} do
      external_id = tenant.external_id

      log =
        capture_log(fn ->
          assert {:ok, db_conn} = Connect.lookup_or_start_connection(external_id, check_connect_region_interval: 100)

          expect(Rebalancer, :check, 1, fn _, _, ^external_id -> {:error, :wrong_region} end)
          reject(&Rebalancer.check/3)

          assert_process_down(db_conn, 500, {:shutdown, :rebalancing})
        end)

      assert log =~ "Rebalancing Tenant database connection"
    end

    test "rebalancing not needed process stays up", %{tenant: tenant} do
      external_id = tenant.external_id
      assert {:ok, db_conn} = Connect.lookup_or_start_connection(external_id, check_connect_region_interval: 100)

      stub(Rebalancer, :check, fn _, _, ^external_id -> :ok end)

      refute_process_down(db_conn)
    end
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

    test "if no users are connected to a tenant channel, stop the connection", %{
      tenant: %{external_id: tenant_id} = tenant
    } do
      {:ok, db_conn} = Connect.lookup_or_start_connection(tenant_id, check_connected_user_interval: 100)

      # Not enough time has passed, connection still alive
      Process.sleep(400)
      region = Tenants.region(tenant)
      assert {_, %{conn: _, region: ^region}} = :syn.lookup(Connect, tenant_id)

      assert_process_down(db_conn, 1000)
      # Enough time has passed, syn has cleaned up
      Process.sleep(100)
      assert :undefined = :syn.lookup(Connect, tenant_id)
      refute Process.alive?(db_conn)
      Connect.shutdown(tenant_id)
    end

    test "if users are connected to a tenant channel, keep the connection", %{
      tenant: %{external_id: tenant_id} = tenant
    } do
      UsersCounter.add(self(), tenant_id)

      {:ok, db_conn} = Connect.lookup_or_start_connection(tenant_id, check_connected_user_interval: 10)

      # Emulate connected user
      UsersCounter.add(self(), tenant_id)
      region = Tenants.region(tenant)
      assert {pid, %{conn: conn_pid, region: ^region}} = :syn.lookup(Connect, tenant_id)
      Process.sleep(300)
      assert {^pid, %{conn: ^conn_pid, region: ^region}} = :syn.lookup(Connect, tenant_id)
      assert Process.alive?(db_conn)

      Connect.shutdown(tenant_id)
    end

    test "connection is killed after user leaving", %{tenant: tenant} do
      external_id = tenant.external_id

      UsersCounter.add(self(), external_id)

      {:ok, db_conn} = Connect.lookup_or_start_connection(external_id, check_connected_user_interval: 10)
      region = Tenants.region(tenant)
      assert {_pid, %{conn: ^db_conn, region: ^region}} = :syn.lookup(Connect, external_id)
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

    test "tenant not able to connect if database has not enough connections", %{
      tenant: tenant
    } do
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

      assert capture_log(fn ->
               assert {:error, :tenant_db_too_many_connections} = Connect.lookup_or_start_connection(tenant.external_id)
             end) =~ ~r/Only \d+ available connections\. At least \d+ connections are required/
    end

    test "handles tenant suspension and unsuspension in a reactive way", %{tenant: tenant} do
      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      assert Connect.ready?(tenant.external_id)

      Realtime.Tenants.suspend_tenant_by_external_id(tenant.external_id)
      assert_process_down(db_conn)
      # Wait for syn to unregister and Cachex to be invalided
      Process.sleep(500)

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
      assert Process.alive?(replication_connection_before)

      assert {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)

      replication_connection_after = ReplicationConnection.whereis(tenant.external_id)
      assert Process.alive?(replication_connection_after)
      assert replication_connection_before == replication_connection_after
    end

    test "on replication connection postgres pid being stopped, Connect module recovers it", %{tenant: tenant} do
      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      assert Connect.ready?(tenant.external_id)

      replication_connection_pid = ReplicationConnection.whereis(tenant.external_id)
      Process.monitor(replication_connection_pid)

      assert Process.alive?(replication_connection_pid)
      pid = Connect.whereis(tenant.external_id)

      Postgrex.query!(
        db_conn,
        "SELECT pg_terminate_backend(pid) from pg_stat_activity where application_name='realtime_replication_connection'",
        []
      )

      assert_receive {:DOWN, _, :process, ^replication_connection_pid, _}

      Process.sleep(1500)
      new_replication_connection_pid = ReplicationConnection.whereis(tenant.external_id)

      assert replication_connection_pid != new_replication_connection_pid
      assert Process.alive?(new_replication_connection_pid)
      assert Process.alive?(pid)
    end

    test "on replication connection exit, Connect module recovers it", %{tenant: tenant} do
      assert {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      assert Connect.ready?(tenant.external_id)

      replication_connection_pid = ReplicationConnection.whereis(tenant.external_id)
      Process.monitor(replication_connection_pid)
      assert Process.alive?(replication_connection_pid)
      pid = Connect.whereis(tenant.external_id)
      Process.exit(replication_connection_pid, :kill)
      assert_receive {:DOWN, _, :process, ^replication_connection_pid, _}

      Process.sleep(1500)
      new_replication_connection_pid = ReplicationConnection.whereis(tenant.external_id)

      assert replication_connection_pid != new_replication_connection_pid
      assert Process.alive?(new_replication_connection_pid)
      assert Process.alive?(pid)
    end

    test "handles max_wal_senders by logging the correct operational code", %{tenant: tenant} do
      opts = tenant |> Database.from_tenant("realtime_test", :stop) |> Database.opts()

      # This creates a loop of errors that occupies all WAL senders and lets us test the error handling
      pids =
        for i <- 0..4 do
          replication_slot_opts =
            %PostgresReplication{
              connection_opts: opts,
              table: :all,
              output_plugin: "pgoutput",
              output_plugin_options: [proto_version: "1", publication_names: "test_#{i}_publication"],
              handler_module: Replication.TestHandler,
              publication_name: "test_#{i}_publication",
              replication_slot_name: "test_#{i}_slot"
            }

          spawn(fn ->
            {:ok, pid} = PostgresReplication.start_link(replication_slot_opts)

            receive do
              :stop -> Process.exit(pid, :kill)
            end
          end)
        end

      on_exit(fn ->
        Enum.each(pids, &send(&1, :stop))
        Process.sleep(2000)
      end)

      log =
        capture_log(fn ->
          assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
          assert_process_down(db_conn)
        end)

      assert log =~ "ReplicationMaxWalSendersReached"
    end

    test "handle rpc errors gracefully" do
      expect(Realtime.Nodes, :get_node_for_tenant, fn _ -> {:ok, :potato@nohost, "us-east-1"} end)

      assert capture_log(fn -> assert {:error, :rpc_error, _} = Connect.lookup_or_start_connection("tenant") end) =~
               "project=tenant external_id=tenant [error] ErrorOnRpcCall"
    end

    test "rate limit connect when too many connections against bad database", %{tenant: tenant} do
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

      log =
        capture_log(fn ->
          res =
            for _ <- 1..50 do
              Process.sleep(200)
              Connect.lookup_or_start_connection(tenant.external_id)
            end

          assert Enum.any?(res, fn {_, res} -> res == :connect_rate_limit_reached end)
        end)

      assert log =~ "DatabaseConnectionRateLimitReached: Too many connection attempts against the tenant database"
    end

    test "rate limit connect will not trigger if connection is successful", %{tenant: tenant} do
      log =
        capture_log(fn ->
          res =
            for _ <- 1..20 do
              Process.sleep(500)
              Connect.lookup_or_start_connection(tenant.external_id)
            end

          refute Enum.any?(res, fn {_, res} -> res == :tenant_db_too_many_connections end)
        end)

      refute log =~ "DatabaseConnectionRateLimitReached: Too many connection attempts against the tenant database"
    end
  end

  describe "shutdown/1" do
    test "shutdowns all associated connections", %{tenant: tenant} do
      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      assert Process.alive?(db_conn)
      assert Connect.ready?(tenant.external_id)
      connect_pid = Connect.whereis(tenant.external_id)
      replication_connection_pid = ReplicationConnection.whereis(tenant.external_id)
      assert Process.alive?(connect_pid)
      assert Process.alive?(replication_connection_pid)

      Connect.shutdown(tenant.external_id)
      assert_process_down(connect_pid)
      assert_process_down(replication_connection_pid)
    end

    test "if tenant does not exist, does nothing" do
      assert :ok = Connect.shutdown("none")
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
