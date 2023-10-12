defmodule Realtime.Tenants.ConnectTest do
  use Realtime.DataCase, async: false
  alias Realtime.Tenants.Connect

  describe "lookup_or_start_connection/1" do
    setup do
      tenant = tenant_fixture()
      %{tenant: tenant}
    end

    test "if tenant exists and connected, returns the db connection", %{tenant: tenant} do
      assert {:ok, conn} = Connect.lookup_or_start_connection(tenant.external_id)
      assert is_pid(conn)
    end

    test "on database disconnect, returns new connection", %{tenant: tenant} do
      assert {:ok, old_conn} = Connect.lookup_or_start_connection(tenant.external_id)
      GenServer.stop(old_conn)
      :timer.sleep(1000)

      assert {:ok, new_conn} = Connect.lookup_or_start_connection(tenant.external_id)
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
            "db_port" => "5432",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1",
            "ssl_enforced" => false
          }
        }
      ]

      tenant = tenant_fixture(%{"extensions" => extensions})

      assert Connect.lookup_or_start_connection(tenant.external_id) ==
               {:error, :tenant_database_unavailable}
    end

    test "if tenant does not exist, returns error" do
      assert Connect.lookup_or_start_connection("none") == {:error, :tenant_not_found}
    end
  end
end
