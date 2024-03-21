defmodule Realtime.Tenants.ConnectTest do
  # async: false due to the fact that multiple operations against the database will use the same connection
  use Realtime.DataCase, async: false

  import Mock

  alias Realtime.Tenants.Connect
  alias Realtime.UsersCounter

  describe "lookup_or_start_connection/1" do
    setup do
      tenant = tenant_fixture()
      %{tenant: tenant}
    end

    test "if tenant exists and connected, returns the db connection", %{tenant: tenant} do
      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)

      on_exit(fn -> Process.exit(db_conn, :normal) end)

      assert is_pid(db_conn)
    end

    test "on database disconnect, returns new connection", %{tenant: tenant} do
      assert {:ok, old_conn} = Connect.lookup_or_start_connection(tenant.external_id)

      GenServer.stop(old_conn)
      :timer.sleep(1000)

      assert {:ok, new_conn} = Connect.lookup_or_start_connection(tenant.external_id)

      on_exit(fn -> Process.exit(new_conn, :normal) end)

      assert new_conn != old_conn
    end

    test "if tenant exists but unable to connect, returns error" do
      extensions = [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
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

      tenant = tenant_fixture(%{"extensions" => extensions})

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
        Connect.lookup_or_start_connection(tenant_id, check_connected_user_interval: 50)

      # Not enough time has passed, connection still alive
      :timer.sleep(100)
      assert {_, %{conn: _}} = :syn.lookup(Connect, tenant_id)

      # Enough time has passed, connection stopped
      :timer.sleep(1000)
      assert :undefined = :syn.lookup(Connect, tenant_id)
      refute Process.alive?(db_conn)
    end

    test "if users are connected to a tenant channel, keep the connection", %{
      tenant: %{external_id: tenant_id}
    } do
      UsersCounter.add(self(), tenant_id)

      {:ok, db_conn} =
        Connect.lookup_or_start_connection(tenant_id, check_connected_user_interval: 10)

      on_exit(fn -> Process.exit(db_conn, :normal) end)

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

      assert {_pid, %{conn: _conn_pid}} = :syn.lookup(Connect, tenant_id)
      :timer.sleep(300)
      :syn.leave(:users, tenant_id, self())
      :timer.sleep(300)
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

      Realtime.Tenants.suspend_tenant_by_external_id(tenant.external_id)

      :timer.sleep(100)

      assert {:error, :tenant_suspended} = Connect.lookup_or_start_connection(tenant.external_id)

      assert Process.alive?(db_conn) == false

      Realtime.Tenants.unsuspend_tenant_by_external_id(tenant.external_id)

      :timer.sleep(100)

      assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)

      on_exit(fn -> Process.exit(db_conn, :normal) end)
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
          Connect.lookup_or_start_connection(tenant.external_id, erpc_timeout: 10_000)
        end)
      end)

      send(check_db_connections_created(self(), tenant.external_id), :check)
      :timer.sleep(5000)
      refute_receive :too_many_connections
    end

    test "on migrations failure, process is alive", %{tenant: tenant} do
      with_mock Ecto.Migrator, [:passthrough], run: fn _, _, _, _ -> nil end do
        assert {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)

        assert_called(Ecto.Migrator.run(:_, :_, :_, :_))
        assert Process.alive?(db_conn) == true
      end
    end

    test "on migrations failure, stop the process", %{tenant: tenant} do
      with_mock Ecto.Migrator, [], run: fn _, _, _, _ -> raise("error") end do
        assert {:error, :tenant_database_unavailable} =
                 Connect.lookup_or_start_connection(tenant.external_id)

        assert_called(Ecto.Migrator.run(:_, :_, :_, :_))
      end
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

          Process.send_after(check_db_connections_created(test_pid, tenant_id), :check, 100)

          if length(processes) > 1 do
            send(test_pid, :too_many_connections)
          end
      end
    end)
  end
end
