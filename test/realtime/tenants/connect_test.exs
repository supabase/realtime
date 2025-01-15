defmodule Realtime.Tenants.ConnectTest do
  # async: false due to the fact that multiple operations against the database will use the same connection
  use Realtime.DataCase, async: false

  import Mock

  alias Ecto.Adapters.SQL.Sandbox
  alias Realtime.Repo
  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Listen
  alias Realtime.Tenants.ReplicationConnection
  alias Realtime.UsersCounter

  describe "lookup_or_start_connection/1" do
    setup do
      tenant = tenant_fixture()
      %{tenant: tenant}
    end

    test "if tenant exists and connected, returns the db connection", %{tenant: tenant} do
      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      Sandbox.allow(Repo, self(), db_conn)
      :timer.sleep(100)
      assert is_pid(db_conn)
    end

    test "on database disconnect, returns new connection", %{tenant: tenant} do
      assert {:ok, old_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      :timer.sleep(500)
      GenServer.stop(old_conn)
      :timer.sleep(500)

      assert {:ok, new_conn} = Connect.lookup_or_start_connection(tenant.external_id)

      on_exit(fn -> Process.exit(new_conn, :shutdown) end)

      assert new_conn != old_conn
    end

    test "if tenant exists but unable to connect, returns error" do
      extensions = [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "localhost",
            "db_name" => "false",
            "db_user" => "false",
            "db_password" => "false",
            "db_port" => "5433",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1",
            "ssl_enforced" => false
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

    test "if no users are connected to a tenant channel, stop the connection", %{
      tenant: %{external_id: tenant_id}
    } do
      {:ok, db_conn} =
        Connect.lookup_or_start_connection(tenant_id, check_connected_user_interval: 200)

      Sandbox.allow(Repo, self(), db_conn)
      # Not enough time has passed, connection still alive
      :timer.sleep(500)
      assert {_, %{conn: _}} = :syn.lookup(Connect, tenant_id)

      # Enough time has passed, connection stopped
      :timer.sleep(5000)
      assert :undefined = :syn.lookup(Connect, tenant_id)
      refute Process.alive?(db_conn)
    end

    test "if users are connected to a tenant channel, keep the connection", %{
      tenant: %{external_id: tenant_id}
    } do
      UsersCounter.add(self(), tenant_id)

      {:ok, db_conn} =
        Connect.lookup_or_start_connection(tenant_id, check_connected_user_interval: 10)

      Process.link(db_conn)
      Sandbox.allow(Repo, self(), db_conn)

      assert {pid, %{conn: conn_pid}} = :syn.lookup(Connect, tenant_id)
      :timer.sleep(300)
      assert {^pid, %{conn: ^conn_pid}} = :syn.lookup(Connect, tenant_id)
      assert Process.alive?(db_conn)
    end

    test "connection is killed after user leaving", %{
      tenant: %{external_id: tenant_id}
    } do
      UsersCounter.add(self(), tenant_id)

      {:ok, db_conn} =
        Connect.lookup_or_start_connection(tenant_id, check_connected_user_interval: 10)

      Process.link(db_conn)
      assert {_pid, %{conn: _conn_pid}} = :syn.lookup(Connect, tenant_id)
      :timer.sleep(1000)
      :syn.leave(:users, tenant_id, self())
      :timer.sleep(1000)
      assert :undefined = :syn.lookup(Connect, tenant_id)
      refute Process.alive?(db_conn)
    end

    test "error if tenant is suspended" do
      tenant = tenant_fixture(suspend: true)

      assert {:error, :tenant_suspended} = Connect.lookup_or_start_connection(tenant.external_id)
    end

    test "handles tenant suspension and unsuspension in a reactive way" do
      tenant = tenant_fixture()

      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      Process.link(db_conn)
      Sandbox.allow(Repo, self(), db_conn)

      :timer.sleep(500)
      Realtime.Tenants.suspend_tenant_by_external_id(tenant.external_id)
      :timer.sleep(500)

      assert {:error, :tenant_suspended} = Connect.lookup_or_start_connection(tenant.external_id)
      assert Process.alive?(db_conn) == false

      Realtime.Tenants.unsuspend_tenant_by_external_id(tenant.external_id)
      :timer.sleep(50)

      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      Sandbox.allow(Repo, self(), db_conn)
      :timer.sleep(100)
    end

    test "properly handles of failing calls by avoid creating too many connections" do
      tenant =
        tenant_fixture(%{
          extensions: [
            %{
              "type" => "postgres_cdc_rls",
              "settings" => %{
                "db_host" => "localhost",
                "db_name" => "postgres",
                "db_user" => "supabase_admin",
                "db_password" => "postgres",
                "db_port" => "5433",
                "poll_interval" => 100,
                "poll_max_changes" => 100,
                "poll_max_record_bytes" => 1_048_576,
                "region" => "us-east-1",
                "ssl_enforced" => true
              }
            }
          ]
        })

      Enum.each(1..10, fn _ ->
        Task.start(fn ->
          Connect.lookup_or_start_connection(tenant.external_id)
        end)
      end)

      send(check_db_connections_created(self(), tenant.external_id), :check)
      :timer.sleep(5000)
      refute_receive :too_many_connections
    end

    test "on migrations failure, stop the process", %{tenant: tenant} do
      with_mock Realtime.Tenants.Migrations, [], run_migrations: fn _ -> raise("error") end do
        assert {:ok, pid} = Connect.lookup_or_start_connection(tenant.external_id)
        Process.sleep(200)
        refute Process.alive?(pid)
        assert_called(Realtime.Tenants.Migrations.run_migrations(tenant))
      end
    end

    test "starts broadcast handler and does not fail on existing connection" do
      tenant = tenant_fixture(%{notify_private_alpha: true})
      on_exit(fn -> Connect.shutdown(tenant.external_id) end)

      assert {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      :timer.sleep(2000)

      replication_connection_before = ReplicationConnection.whereis(tenant.external_id)
      assert Process.alive?(replication_connection_before)
      assert {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)

      replication_connection_after = ReplicationConnection.whereis(tenant.external_id)
      assert Process.alive?(replication_connection_after)
      assert replication_connection_before == replication_connection_after
    end

    test "failed broadcast handler and listen recover from failure" do
      tenant = tenant_fixture(%{notify_private_alpha: true})
      on_exit(fn -> Connect.shutdown(tenant.external_id) end)
      assert {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      :timer.sleep(3000)

      replication_connection_pid = ReplicationConnection.whereis(tenant.external_id)
      listen_pid = ReplicationConnection.whereis(tenant.external_id)
      assert Process.alive?(replication_connection_pid)
      assert Process.alive?(listen_pid)

      Process.exit(replication_connection_pid, :kill)
      Process.exit(listen_pid, :kill)

      refute Process.alive?(replication_connection_pid)
      refute Process.alive?(listen_pid)

      :timer.sleep(1000)
      replication_connection_pid = ReplicationConnection.whereis(tenant.external_id)
      listen_pid = ReplicationConnection.whereis(tenant.external_id)
      assert Process.alive?(replication_connection_pid)
      assert Process.alive?(listen_pid)
    end

    test "on database disconnect, connection is killed to all components" do
      tenant = tenant_fixture(%{notify_private_alpha: true})
      on_exit(fn -> Connect.shutdown(tenant.external_id) end)
      assert {:ok, _db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      old_pid = Connect.whereis(tenant.external_id)
      :timer.sleep(3000)

      old_replication_connection_pid = ReplicationConnection.whereis(tenant.external_id)
      old_listen_connection_pid = Listen.whereis(tenant.external_id)

      assert Process.alive?(old_replication_connection_pid)
      assert Process.alive?(old_listen_connection_pid)

      System.cmd("docker", ["stop", "tenant-db"])
      :timer.sleep(500)
      System.cmd("docker", ["start", "tenant-db"])

      :timer.sleep(3000)
      refute Process.alive?(old_pid)
      refute Process.alive?(old_replication_connection_pid)
      refute Process.alive?(old_listen_connection_pid)

      assert ReplicationConnection.whereis(tenant.external_id) == nil
      assert Listen.whereis(tenant.external_id) == nil
    end
  end

  describe "shutdown/1" do
    test "shutdowns all associated connections" do
      tenant = tenant_fixture(%{notify_private_alpha: true})

      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      Process.sleep(1000)

      assert Process.alive?(db_conn)
      assert Process.alive?(Connect.whereis(tenant.external_id))
      assert Process.alive?(ReplicationConnection.whereis(tenant.external_id))
      assert Process.alive?(Listen.whereis(tenant.external_id))

      Connect.shutdown(tenant.external_id)
      Process.sleep(1000)
      refute Connect.whereis(tenant.external_id)
      refute ReplicationConnection.whereis(tenant.external_id)
      refute Listen.whereis(tenant.external_id)
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
