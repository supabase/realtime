defmodule Realtime.ApiTest do
  # async: false due to the fact that interacts with Realtime.Repo which means it might capture more entries than expected and due to usage of mocks
  use Realtime.DataCase, async: true

  import Mock

  alias Realtime.Api
  alias Realtime.Api.Extensions
  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  @db_conf Application.compile_env(:realtime, Realtime.Repo)

  setup do
    start_supervised(Realtime.RateCounter)
    start_supervised(Realtime.GenCounter)

    tenant_fixture(%{max_concurrent_users: 10_000_000})
    tenant_fixture(%{max_concurrent_users: 25_000_000})
    tenants = Api.list_tenants()

    %{tenants: tenants}
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
               tenants |> Enum.sort_by(& &1.max_concurrent_users, :desc) |> Enum.take(2)
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
    test "valid data updates the tenant" do
      tenant = tenant_fixture()

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

    test "invalid data returns error changeset", %{tenants: [tenant | _]} do
      assert {:error, %Ecto.Changeset{}} = Api.update_tenant(tenant, %{external_id: nil, jwt_secret: nil, name: nil})
    end

    test "valid data and jwks change will send disconnect event" do
      tenant = tenant_fixture()
      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant.external_id)

      assert {:ok, %Tenant{}} = Api.update_tenant(tenant, %{jwt_jwks: %{keys: ["test"]}})
      assert_receive :disconnect, 500
    end

    test "valid data and jwt_secret change will send disconnect event" do
      tenant = tenant_fixture()
      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant.external_id)

      assert {:ok, %Tenant{}} = Api.update_tenant(tenant, %{jwt_secret: "potato"})

      assert_receive :disconnect, 500
    end

    test "valid data but not updating jwt_secret or jwt_jwks won't send event" do
      tenant = tenant_fixture()
      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant.external_id)

      assert {:ok, %Tenant{}} = Api.update_tenant(tenant, %{max_events_per_second: 100})
      refute_receive :disconnect, 500
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

  describe "change_tenant/1" do
    test "returns a tenant changeset", %{tenants: [tenant | _]} do
      assert %Ecto.Changeset{} = Api.change_tenant(tenant)
    end
  end

  test "list_extensions/1 ", %{tenants: tenants} do
    assert length(Api.list_extensions()) == length(tenants)
  end

  describe "preload_counters/1" do
    test "preloads counters for a given tenant ", %{tenants: [tenant | _]} do
      tenant = Repo.reload!(tenant)
      assert Api.preload_counters(nil) == nil

      with_mocks([
        {GenCounter, [:passthrough], [get: fn _ -> {:ok, 1} end]},
        {RateCounter, [:passthrough], [get: fn _ -> {:ok, %RateCounter{avg: 2}} end]}
      ]) do
        counters = Api.preload_counters(tenant)
        assert counters.events_per_second_rolling == 2
        assert counters.events_per_second_now == 1
      end

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
end
