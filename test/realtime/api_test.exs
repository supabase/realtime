defmodule Realtime.ApiTest do
  use Realtime.DataCase, async: false

  import Mock

  alias Realtime.Api
  alias Realtime.Api.Extensions
  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.GenCounter
  alias Realtime.RateCounter

  @db_conf Application.compile_env(:realtime, Realtime.Repo)

  @valid_attrs %{
    external_id: "external_id",
    name: "localhost",
    extensions: [
      %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "db_host" => @db_conf[:hostname],
          "db_name" => @db_conf[:database],
          "db_user" => @db_conf[:username],
          "db_password" => @db_conf[:password],
          "db_port" => "5433",
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

  @update_attrs %{
    external_id: "external_id1",
    jwt_secret: "some updated jwt_secret",
    name: "some updated name"
  }
  @invalid_attrs %{external_id: nil, jwt_secret: nil, name: nil}

  setup do
    tenants = [
      tenant_fixture(%{external_id: "external_id1", max_concurrent_users: 10}),
      tenant_fixture(%{external_id: "external_id2", max_concurrent_users: 5}),
      tenant_fixture(%{external_id: "external_id3", max_concurrent_users: 15}),
      tenant_fixture(%{external_id: "external_id4", max_concurrent_users: 20}),
      tenant_fixture(%{external_id: "external_id5", max_concurrent_users: 25})
    ]

    dev_tenant = Api.list_tenants(search: "dev_tenant")
    tenants = tenants ++ dev_tenant

    %{tenants: tenants}
  end

  describe "tenants" do
    test "list_tenants/0 returns all tenants", %{tenants: tenants} do
      assert Enum.sort(Api.list_tenants()) == Enum.sort(tenants)
    end

    test "list_tenants/1 returns filtered tenants", %{tenants: tenants} do
      assert hd(Api.list_tenants(search: hd(tenants).external_id)) == hd(tenants)

      assert Api.list_tenants(order_by: "max_concurrent_users") ==
               Enum.sort_by(tenants, & &1.max_concurrent_users, :desc)

      assert Api.list_tenants(order_by: "max_concurrent_users", order: "asc") ==
               Enum.sort_by(tenants, & &1.max_concurrent_users, :asc)

      assert Api.list_tenants(order_by: "max_concurrent_users", order: "asc", limit: 2) ==
               tenants |> Enum.sort_by(& &1.max_concurrent_users, :asc) |> Enum.take(2)
    end

    test "get_tenant!/1 returns the tenant with given id", %{tenants: [tenant | _]} do
      result = Api.get_tenant!(tenant.id) |> Map.delete(:extensions)
      expected = tenant |> Map.delete(:extensions)
      assert result == expected
    end

    test "create_tenant/1 with valid data creates a tenant" do
      assert {:ok, %Tenant{} = tenant} = Api.create_tenant(@valid_attrs)

      assert tenant.external_id == "external_id"
      assert tenant.jwt_secret == "YIriPuuJO1uerq5hSZ1W5Q=="
      assert tenant.name == "localhost"
    end

    test "create_tenant/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Api.create_tenant(@invalid_attrs)
    end

    test "check get_tenant_by_external_id/1", %{tenants: [tenant | _]} do
      %Tenant{extensions: [%Extensions{} = extension]} =
        Api.get_tenant_by_external_id(tenant.external_id)

      assert Map.has_key?(extension.settings, "db_password")
      password = extension.settings["db_password"]
      assert ^password = "v1QVng3N+pZd/0AEObABwg=="
    end

    test "update_tenant/2 with valid data updates the tenant", %{tenants: [tenant | _]} do
      assert {:ok, %Tenant{} = tenant} = Api.update_tenant(tenant, @update_attrs)
      assert tenant.external_id == "external_id1"

      assert tenant.jwt_secret == Crypto.encrypt!("some updated jwt_secret")
      assert tenant.name == "some updated name"
    end

    test "update_tenant/2 with invalid data returns error changeset", %{tenants: [tenant | _]} do
      assert {:error, %Ecto.Changeset{}} = Api.update_tenant(tenant, @invalid_attrs)
    end

    test "delete_tenant/1 deletes the tenant", %{tenants: [tenant | _]} do
      assert {:ok, %Tenant{}} = Api.delete_tenant(tenant)
      assert_raise Ecto.NoResultsError, fn -> Api.get_tenant!(tenant.id) end
    end

    test "delete_tenant_by_external_id/1 deletes the tenant", %{tenants: [tenant | _]} do
      assert true == Api.delete_tenant_by_external_id(tenant.external_id)
      assert false == Api.delete_tenant_by_external_id("undef_tenant")
      assert_raise Ecto.NoResultsError, fn -> Api.get_tenant!(tenant.id) end
    end

    test "change_tenant/1 returns a tenant changeset", %{tenants: [tenant | _]} do
      assert %Ecto.Changeset{} = Api.change_tenant(tenant)
    end

    test "list_extensions/1 ", %{tenants: tenants} do
      assert length(Api.list_extensions()) == length(tenants)
    end

    test "preload_counters/1 ", %{tenants: [tenant | _]} do
      assert Api.preload_counters(nil) == nil

      with_mocks([
        {GenCounter, [], [get: fn _ -> {:ok, 1} end]},
        {RateCounter, [], [get: fn _ -> {:ok, %RateCounter{avg: 2}} end]}
      ]) do
        counters = Api.preload_counters(tenant)
        assert counters.events_per_second_rolling == 2
        assert counters.events_per_second_now == 1
      end

      assert Api.preload_counters(nil, :any) == nil
    end

    test "rename_settings_field/2", %{tenants: [tenant | _]} do
      Api.rename_settings_field("poll_interval_ms", "poll_interval")
      assert %{extensions: [%{settings: %{"poll_interval" => _}}]} = tenant
    end
  end
end
