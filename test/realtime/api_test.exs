defmodule Realtime.ApiTest do
  use Realtime.DataCase, async: false

  use Mimic

  alias Realtime.Api
  alias Realtime.Api.Extensions
  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants.Connect

  @db_conf Application.compile_env(:realtime, Realtime.Repo)

  setup do
    tenant1 = Containers.checkout_tenant(run_migrations: true)
    tenant2 = Containers.checkout_tenant(run_migrations: true)
    Api.update_tenant(tenant1, %{max_concurrent_users: 10_000_000})
    Api.update_tenant(tenant2, %{max_concurrent_users: 20_000_000})

    %{tenants: Api.list_tenants(), tenant: tenant1}
  end

  describe "list_tenants/0" do
    test "returns all tenants", %{tenants: tenants} do
      assert Enum.sort(Api.list_tenants()) == Enum.sort(tenants)
    end
  end

  describe "list_tenants/1" do
    test "list_tenants/1 returns filtered tenants", %{tenants: tenants} do
      assert hd(Api.list_tenants(search: hd(tenants).external_id)) == hd(tenants)

      assert Api.list_tenants(order_by: "max_concurrent_users", order: "desc", limit: 2) ==
               Enum.sort_by(tenants, & &1.max_concurrent_users, :desc) |> Enum.take(2)
    end
  end

  describe "get_tenant!/1" do
    test "returns the tenant with given id", %{tenants: [tenant | _]} do
      result = tenant.id |> Api.get_tenant!() |> Map.delete(:extensions)
      expected = tenant |> Map.delete(:extensions)
      assert result == expected
    end
  end

  describe "create_tenant/1" do
    test "valid data creates a tenant" do
      port = Generators.port()

      external_id = random_string()

      valid_attrs = %{
        external_id: external_id,
        name: external_id,
        extensions: [
          %{
            "type" => "postgres_cdc_rls",
            "settings" => %{
              "db_host" => @db_conf[:hostname],
              "db_name" => @db_conf[:database],
              "db_user" => @db_conf[:username],
              "db_password" => @db_conf[:password],
              "db_port" => "#{port}",
              "poll_interval" => 100,
              "poll_max_changes" => 100,
              "poll_max_record_bytes" => 1_048_576,
              "region" => "us-east-1"
            }
          }
        ],
        postgres_cdc_default: "postgres_cdc_rls",
        jwt_secret: "new secret",
        max_concurrent_users: 200,
        max_events_per_second: 100
      }

      assert {:ok, %Tenant{} = tenant} = Api.create_tenant(valid_attrs)

      assert tenant.external_id == external_id
      assert tenant.jwt_secret == "YIriPuuJO1uerq5hSZ1W5Q=="
      assert tenant.name == external_id
      assert tenant.broadcast_adapter == :gen_rpc
    end

    test "invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Api.create_tenant(%{external_id: nil, jwt_secret: nil, name: nil})
    end
  end

  describe "get_tenant_by_external_id/1" do
    test "fetch by external id", %{tenants: [tenant | _]} do
      %Tenant{extensions: [%Extensions{} = extension]} =
        Api.get_tenant_by_external_id(tenant.external_id)

      assert Map.has_key?(extension.settings, "db_password")
      password = extension.settings["db_password"]
      assert ^password = "v1QVng3N+pZd/0AEObABwg=="
    end
  end

  describe "update_tenant/2" do
    test "valid data updates the tenant", %{tenant: tenant} do
      update_attrs = %{
        external_id: tenant.external_id,
        jwt_secret: "some updated jwt_secret",
        name: "some updated name"
      }

      assert {:ok, %Tenant{} = tenant} = Api.update_tenant(tenant, update_attrs)
      assert tenant.external_id == tenant.external_id

      assert tenant.jwt_secret == Crypto.encrypt!("some updated jwt_secret")
      assert tenant.name == "some updated name"
    end

    test "invalid data returns error changeset", %{tenant: tenant} do
      assert {:error, %Ecto.Changeset{}} = Api.update_tenant(tenant, %{external_id: nil, jwt_secret: nil, name: nil})
    end

    test "valid data and jwks change will send disconnect event", %{tenant: tenant} do
      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant.external_id)
      assert {:ok, %Tenant{}} = Api.update_tenant(tenant, %{jwt_jwks: %{keys: ["test"]}})
      assert_receive :disconnect, 500
    end

    test "valid data and jwt_secret change will send disconnect event", %{tenant: tenant} do
      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant.external_id)
      assert {:ok, %Tenant{}} = Api.update_tenant(tenant, %{jwt_secret: "potato"})
      assert_receive :disconnect, 500
    end

    test "valid data and suspend change will send disconnect event", %{tenant: tenant} do
      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant.external_id)
      assert {:ok, %Tenant{}} = Api.update_tenant(tenant, %{suspend: true})
      assert_receive :disconnect, 500
    end

    test "valid data but not updating jwt_secret or jwt_jwks won't send event", %{tenant: tenant} do
      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant.external_id)
      assert {:ok, %Tenant{}} = Api.update_tenant(tenant, %{max_events_per_second: 100})
      refute_receive :disconnect, 500
    end

    test "valid data and jwt_secret change will restart the database connection", %{tenant: tenant} do
      {:ok, old_pid} = Connect.lookup_or_start_connection(tenant.external_id)

      Process.monitor(old_pid)
      assert {:ok, %Tenant{}} = Api.update_tenant(tenant, %{jwt_secret: "potato"})
      assert_receive {:DOWN, _, :process, ^old_pid, :shutdown}, 500
      refute Process.alive?(old_pid)
      Process.sleep(100)
      assert {:ok, new_pid} = Connect.lookup_or_start_connection(tenant.external_id)
      assert %Postgrex.Result{} = Postgrex.query!(new_pid, "SELECT 1", [])
    end

    test "valid data and suspend change will restart the database connection", %{tenant: tenant} do
      {:ok, old_pid} = Connect.lookup_or_start_connection(tenant.external_id)

      Process.monitor(old_pid)
      assert {:ok, %Tenant{}} = Api.update_tenant(tenant, %{suspend: true})
      assert_receive {:DOWN, _, :process, ^old_pid, :shutdown}, 500
      refute Process.alive?(old_pid)
      Process.sleep(100)
      assert {:error, :tenant_suspended} = Connect.lookup_or_start_connection(tenant.external_id)
    end

    test "valid data and tenant data change will not restart the database connection", %{tenant: tenant} do
      {:ok, old_pid} = Connect.lookup_or_start_connection(tenant.external_id)

      assert {:ok, %Tenant{}} = Api.update_tenant(tenant, %{max_concurrent_users: 100})
      refute_receive {:DOWN, _, :process, ^old_pid, :shutdown}, 500
      assert Process.alive?(old_pid)
      assert {:ok, new_pid} = Connect.lookup_or_start_connection(tenant.external_id)
      assert old_pid == new_pid
    end

    test "valid data and extensions data change will restart the database connection", %{tenant: tenant} do
      config = Realtime.Database.from_tenant(tenant, "realtime_test", :stop)

      extensions = [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
            "db_name" => "postgres",
            "db_user" => "supabase_admin",
            "db_password" => "postgres",
            "db_port" => "#{config.port}",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1",
            "publication" => "supabase_realtime_test",
            "ssl_enforced" => false
          }
        }
      ]

      {:ok, old_pid} = Connect.lookup_or_start_connection(tenant.external_id)
      Process.monitor(old_pid)
      assert {:ok, %Tenant{}} = Api.update_tenant(tenant, %{extensions: extensions})
      assert_receive {:DOWN, _, :process, ^old_pid, :shutdown}, 500
      refute Process.alive?(old_pid)
      Process.sleep(100)
      assert {:ok, new_pid} = Connect.lookup_or_start_connection(tenant.external_id)
      assert %Postgrex.Result{} = Postgrex.query!(new_pid, "SELECT 1", [])
    end

    test "valid data and change to tenant data will refresh cache", %{tenant: tenant} do
      assert {:ok, %Tenant{}} = Api.update_tenant(tenant, %{name: "new_name"})
      assert %Tenant{name: "new_name"} = Realtime.Tenants.Cache.get_tenant_by_external_id(tenant.external_id)
    end

    test "valid data and no changes to tenant will not refresh cache", %{tenant: tenant} do
      reject(&Realtime.Tenants.Cache.get_tenant_by_external_id/1)
      assert {:ok, %Tenant{}} = Api.update_tenant(tenant, %{name: tenant.name})
    end
  end

  describe "delete_tenant/1" do
    test "deletes the tenant" do
      tenant = tenant_fixture()
      assert {:ok, %Tenant{}} = Api.delete_tenant(tenant)
      assert_raise Ecto.NoResultsError, fn -> Api.get_tenant!(tenant.id) end
    end
  end

  describe "delete_tenant_by_external_id/1" do
    test "deletes the tenant" do
      tenant = tenant_fixture()
      assert true == Api.delete_tenant_by_external_id(tenant.external_id)
      assert false == Api.delete_tenant_by_external_id("undef_tenant")
      assert_raise Ecto.NoResultsError, fn -> Api.get_tenant!(tenant.id) end
    end
  end

  describe "preload_counters/1" do
    test "preloads counters for a given tenant ", %{tenants: [tenant | _]} do
      tenant = Repo.reload!(tenant)
      assert Api.preload_counters(nil) == nil

      expect(GenCounter, :get, fn _ -> 1 end)
      expect(RateCounter, :get, fn _ -> {:ok, %RateCounter{avg: 2}} end)
      counters = Api.preload_counters(tenant)
      assert counters.events_per_second_rolling == 2
      assert counters.events_per_second_now == 1

      assert Api.preload_counters(nil, :any) == nil
    end
  end

  describe "rename_settings_field/2" do
    test "renames setting fields" do
      tenant = tenant_fixture()
      Api.rename_settings_field("poll_interval_ms", "poll_interval")
      assert %{extensions: [%{settings: %{"poll_interval" => _}}]} = tenant
    end
  end

  describe "requires_disconnect/1" do
    defmodule TestRequiresDisconnect do
      import Api

      def check(changeset) when requires_disconnect(changeset), do: true
      def check(_changeset), do: false
    end

    test "returns true if jwt_secret is changed" do
      changeset = %Ecto.Changeset{valid?: true, changes: %{jwt_secret: "new_secret"}}
      assert TestRequiresDisconnect.check(changeset)
    end

    test "returns true if jwt_jwks is changed" do
      changeset = %Ecto.Changeset{valid?: true, changes: %{jwt_jwks: %{keys: ["test"]}}}
      assert TestRequiresDisconnect.check(changeset)
    end

    test "returns true if private_only is changed" do
      changeset = %Ecto.Changeset{valid?: true, changes: %{private_only: true}}
      assert TestRequiresDisconnect.check(changeset)
    end

    test "returns true if suspend is changed" do
      changeset = %Ecto.Changeset{valid?: true, changes: %{suspend: true}}
      assert TestRequiresDisconnect.check(changeset)
    end

    test "returns false if valid? is false" do
      changeset = %Ecto.Changeset{valid?: false, changes: %{jwt_secret: "new_secret"}}
      refute TestRequiresDisconnect.check(changeset)
    end
  end

  describe "requires_restarting_db_connection/1" do
    defmodule TestRequiresRestartingDbConnection do
      import Api

      def check(changeset) when requires_restarting_db_connection(changeset), do: true
      def check(_changeset), do: false
    end

    test "returns true if extensions is changed" do
      changeset = %Ecto.Changeset{valid?: true, changes: %{extensions: []}}
      assert TestRequiresRestartingDbConnection.check(changeset)
    end

    test "returns true if jwt_secret are changed" do
      changeset = %Ecto.Changeset{valid?: true, changes: %{jwt_secret: "new_secret"}}
      assert TestRequiresRestartingDbConnection.check(changeset)
    end

    test "returns true if jwt_jwks are changed" do
      changeset = %Ecto.Changeset{valid?: true, changes: %{jwt_jwks: %{keys: ["test"]}}}
      assert TestRequiresRestartingDbConnection.check(changeset)
    end

    test "returns true if suspend is changed" do
      changeset = %Ecto.Changeset{valid?: true, changes: %{suspend: true}}
      assert TestRequiresRestartingDbConnection.check(changeset)
    end

    test "returns true if multiple relevant fields are changed" do
      changeset = %Ecto.Changeset{valid?: true, changes: %{jwt_secret: "new_secret", jwt_jwks: %{keys: ["test"]}}}
      assert TestRequiresRestartingDbConnection.check(changeset)
    end

    test "returns false if no relevant fields are changed" do
      changeset = %Ecto.Changeset{valid?: true, changes: %{postgres_cdc_default: "potato"}}
      refute TestRequiresRestartingDbConnection.check(changeset)
    end

    test "returns false if valid? is false" do
      changeset = %Ecto.Changeset{valid?: false, changes: %{jwt_secret: "new_secret"}}
      refute TestRequiresRestartingDbConnection.check(changeset)
    end
  end
end
