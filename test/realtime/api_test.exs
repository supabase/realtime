defmodule Realtime.ApiTest do
  use Realtime.DataCase, async: true

  use Mimic

  alias Realtime.Api
  alias Realtime.Api.Extensions, as: ApiExtensions
  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants.Connect
  alias Extensions.PostgresCdcRls

  @db_conf Application.compile_env(:realtime, Realtime.Repo)

  defp create_tenants(_) do
    tenant1 = tenant_fixture(%{max_concurrent_users: 10_000_000})
    tenant2 = tenant_fixture(%{max_concurrent_users: 20_000_000})
    dev_tenant = Realtime.Api.get_tenant_by_external_id("dev_tenant")
    %{tenants: [tenant1, tenant2, dev_tenant]}
  end

  describe "list_tenants/0" do
    setup [:create_tenants]

    test "returns all tenants", %{tenants: tenants} do
      assert Enum.sort(Api.list_tenants()) == Enum.sort(tenants)
    end
  end

  describe "list_tenants/1" do
    setup [:create_tenants]

    test "list_tenants/1 returns filtered tenants", %{tenants: tenants} do
      assert hd(Api.list_tenants(search: hd(tenants).external_id)) == hd(tenants)

      assert Api.list_tenants(order_by: "max_concurrent_users", order: "desc", limit: 2) ==
               Enum.sort_by(tenants, & &1.max_concurrent_users, :desc) |> Enum.take(2)
    end
  end

  describe "get_tenant!/1" do
    setup [:create_tenants]

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

      expect(Realtime.Tenants.Cache, :global_cache_update, fn tenant ->
        assert tenant.external_id == external_id
      end)

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
      reject(&Realtime.Tenants.Cache.global_cache_update/1)
      assert {:error, %Ecto.Changeset{}} = Api.create_tenant(%{external_id: nil, jwt_secret: nil, name: nil})
    end
  end

  describe "get_tenant_by_external_id/2" do
    setup [:create_tenants]

    test "fetch by external id", %{tenants: [tenant | _]} do
      %Tenant{extensions: [%ApiExtensions{} = extension]} =
        Api.get_tenant_by_external_id(tenant.external_id)

      assert Map.has_key?(extension.settings, "db_password")
      password = extension.settings["db_password"]
      assert ^password = "v1QVng3N+pZd/0AEObABwg=="
    end

    test "fetch by external id using replica", %{tenants: [tenant | _]} do
      %Tenant{extensions: [%ApiExtensions{} = extension]} =
        Api.get_tenant_by_external_id(tenant.external_id, use_replica?: true)

      assert Map.has_key?(extension.settings, "db_password")
      password = extension.settings["db_password"]
      assert ^password = "v1QVng3N+pZd/0AEObABwg=="
    end

    test "fetch by external id using no replica", %{tenants: [tenant | _]} do
      %Tenant{extensions: [%ApiExtensions{} = extension]} =
        Api.get_tenant_by_external_id(tenant.external_id, use_replica?: false)

      assert Map.has_key?(extension.settings, "db_password")
      password = extension.settings["db_password"]
      assert ^password = "v1QVng3N+pZd/0AEObABwg=="
    end
  end

  describe "update_tenant_by_external_id/2" do
    setup [:create_tenants]

    test "valid data updates the tenant using external_id", %{tenants: [tenant | _]} do
      update_attrs = %{
        external_id: tenant.external_id,
        jwt_secret: "some updated jwt_secret",
        name: "some updated name"
      }

      assert {:ok, %Tenant{} = tenant} = Api.update_tenant_by_external_id(tenant.external_id, update_attrs)
      assert tenant.external_id == tenant.external_id

      assert tenant.jwt_secret == Crypto.encrypt!("some updated jwt_secret")
      assert tenant.name == "some updated name"
    end

    test "invalid data returns error changeset", %{tenants: [tenant | _]} do
      assert {:error, %Ecto.Changeset{}} =
               Api.update_tenant_by_external_id(tenant.external_id, %{external_id: nil, jwt_secret: nil, name: nil})
    end

    test "valid data and jwks change will send disconnect event", %{tenants: [tenant | _]} do
      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant.external_id)
      assert {:ok, %Tenant{}} = Api.update_tenant_by_external_id(tenant.external_id, %{jwt_jwks: %{keys: ["test"]}})
      assert_receive :disconnect, 500
    end

    test "valid data and jwt_secret change will send disconnect event", %{tenants: [tenant | _]} do
      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant.external_id)
      assert {:ok, %Tenant{}} = Api.update_tenant_by_external_id(tenant.external_id, %{jwt_secret: "potato"})
      assert_receive :disconnect, 500
    end

    test "valid data and suspend change will send disconnect event", %{tenants: [tenant | _]} do
      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant.external_id)
      assert {:ok, %Tenant{}} = Api.update_tenant_by_external_id(tenant.external_id, %{suspend: true})
      assert_receive :disconnect, 500
    end

    test "valid data but not updating jwt_secret or jwt_jwks won't send event", %{tenants: [tenant | _]} do
      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant.external_id)
      assert {:ok, %Tenant{}} = Api.update_tenant_by_external_id(tenant.external_id, %{max_events_per_second: 100})
      refute_receive :disconnect, 500
    end

    test "valid data and jwt_secret change will restart the database connection", %{tenants: [tenant | _]} do
      expect(Connect, :shutdown, fn external_id ->
        assert external_id == tenant.external_id
        :ok
      end)

      expect(PostgresCdcRls, :handle_stop, fn external_id, timeout ->
        assert external_id == tenant.external_id
        assert timeout == 5_000
        :ok
      end)

      assert {:ok, %Tenant{}} = Api.update_tenant_by_external_id(tenant.external_id, %{jwt_secret: "potato"})
    end

    test "valid data and suspend change will restart the database connection", %{tenants: [tenant | _]} do
      expect(Connect, :shutdown, fn external_id ->
        assert external_id == tenant.external_id
        :ok
      end)

      expect(PostgresCdcRls, :handle_stop, fn external_id, timeout ->
        assert external_id == tenant.external_id
        assert timeout == 5_000
        :ok
      end)

      assert {:ok, %Tenant{}} = Api.update_tenant_by_external_id(tenant.external_id, %{suspend: true})
    end

    test "valid data and tenant data change will not restart the database connection", %{tenants: [tenant | _]} do
      reject(&Connect.shutdown/1)
      reject(&PostgresCdcRls.handle_stop/2)

      expect(Realtime.Tenants.Cache, :global_cache_update, fn tenant ->
        assert tenant.max_concurrent_users == 101
      end)

      assert {:ok, %Tenant{}} = Api.update_tenant_by_external_id(tenant.external_id, %{max_concurrent_users: 101})
    end

    test "valid data and extensions data change will restart the database connection", %{tenants: [tenant | _]} do
      extensions = [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
            "db_name" => "postgres",
            "db_user" => "supabase_admin",
            "db_password" => "postgres",
            "db_port" => "5432",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1",
            "publication" => "supabase_realtime_test",
            "ssl_enforced" => false
          }
        }
      ]

      expect(Connect, :shutdown, fn external_id ->
        assert external_id == tenant.external_id
        :ok
      end)

      expect(PostgresCdcRls, :handle_stop, fn external_id, timeout ->
        assert external_id == tenant.external_id
        assert timeout == 5_000
        :ok
      end)

      assert {:ok, %Tenant{}} = Api.update_tenant_by_external_id(tenant.external_id, %{extensions: extensions})
    end

    test "valid data and jwt_jwks change will restart the database connection", %{tenants: [tenant | _]} do
      expect(Connect, :shutdown, fn external_id ->
        assert external_id == tenant.external_id
        :ok
      end)

      expect(PostgresCdcRls, :handle_stop, fn external_id, timeout ->
        assert external_id == tenant.external_id
        assert timeout == 5_000
        :ok
      end)

      assert {:ok, %Tenant{}} = Api.update_tenant_by_external_id(tenant.external_id, %{jwt_jwks: %{keys: ["test"]}})
    end

    test "valid data and jwt_secret change will restart DB connection even if handle_stop times out", %{
      tenants: [tenant | _]
    } do
      expect(Connect, :shutdown, fn external_id ->
        assert external_id == tenant.external_id
        :ok
      end)

      expect(PostgresCdcRls, :handle_stop, fn _external_id, _timeout ->
        # Simulate timeout exit like DynamicSupervisor.stop/3 does
        exit(:timeout)
      end)

      # Update should still succeed even if handle_stop times out
      assert {:ok, %Tenant{}} = Api.update_tenant_by_external_id(tenant.external_id, %{jwt_secret: "potato"})
    end

    test "valid data and change to tenant data will refresh cache", %{tenants: [tenant | _]} do
      expect(Realtime.Tenants.Cache, :global_cache_update, fn tenant ->
        assert tenant.name == "new_name"
      end)

      assert {:ok, %Tenant{}} = Api.update_tenant_by_external_id(tenant.external_id, %{name: "new_name"})
    end

    test "valid data and no changes to tenant will not refresh cache", %{tenants: [tenant | _]} do
      reject(&Realtime.Tenants.Cache.global_cache_update/1)
      assert {:ok, %Tenant{}} = Api.update_tenant_by_external_id(tenant.external_id, %{name: tenant.name})
    end

    test "change to max_events_per_second publishes update to respective rate counters", %{tenants: [tenant | _]} do
      expect(RateCounter, :publish_update, fn key ->
        assert key == Realtime.Tenants.events_per_second_key(tenant.external_id)
      end)

      expect(RateCounter, :publish_update, fn key ->
        assert key == Realtime.Tenants.db_events_per_second_key(tenant.external_id)
      end)

      reject(&RateCounter.publish_update/1)

      assert {:ok, %Tenant{}} = Api.update_tenant_by_external_id(tenant.external_id, %{max_events_per_second: 123})
    end

    test "change to max_joins_per_second publishes update to rate counters", %{tenants: [tenant | _]} do
      expect(RateCounter, :publish_update, fn key ->
        assert key == Realtime.Tenants.joins_per_second_key(tenant.external_id)
      end)

      reject(&RateCounter.publish_update/1)

      assert {:ok, %Tenant{}} = Api.update_tenant_by_external_id(tenant.external_id, %{max_joins_per_second: 123})
    end

    test "change to max_presence_events_per_second publishes update to rate counters", %{tenants: [tenant | _]} do
      expect(RateCounter, :publish_update, fn key ->
        assert key == Realtime.Tenants.presence_events_per_second_key(tenant.external_id)
      end)

      reject(&RateCounter.publish_update/1)

      assert {:ok, %Tenant{}} =
               Api.update_tenant_by_external_id(tenant.external_id, %{max_presence_events_per_second: 123})
    end

    test "change to extensions publishes update to rate counters", %{tenants: [tenant | _]} do
      extensions = [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
            "db_name" => "postgres",
            "db_user" => "supabase_admin",
            "db_password" => "postgres",
            "db_port" => "1234",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1",
            "publication" => "supabase_realtime_test",
            "ssl_enforced" => false
          }
        }
      ]

      expect(RateCounter, :publish_update, fn key ->
        assert key == Realtime.Tenants.connect_errors_per_second_key(tenant.external_id)
      end)

      expect(RateCounter, :publish_update, fn key ->
        assert key == Realtime.Tenants.subscription_errors_per_second_key(tenant.external_id)
      end)

      expect(RateCounter, :publish_update, fn key ->
        assert key == Realtime.Tenants.authorization_errors_per_second_key(tenant.external_id)
      end)

      reject(&RateCounter.publish_update/1)

      assert {:ok, %Tenant{}} = Api.update_tenant_by_external_id(tenant.external_id, %{extensions: extensions})
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
    setup [:create_tenants]

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
    @tag skip: "** (Postgrex.Error) ERROR 0A000 (feature_not_supported) cached plan must not change result type"
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

  describe "update_migrations_ran/1" do
    test "updates migrations_ran to the count of all migrations" do
      tenant = tenant_fixture(%{migrations_ran: 0})

      expect(Realtime.Tenants.Cache, :global_cache_update, fn tenant ->
        assert tenant.migrations_ran == 1
        :ok
      end)

      assert {:ok, tenant} = Api.update_migrations_ran(tenant.external_id, 1)
      assert tenant.migrations_ran == 1
    end
  end
end
