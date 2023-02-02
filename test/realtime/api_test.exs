defmodule Realtime.ApiTest do
  use Realtime.DataCase

  import Mock

  alias Realtime.Api
  alias Realtime.{Api, RateCounter, GenCounter}

  describe "tenants" do
    alias Realtime.Api.{Tenant, Extensions}
    db_conf = Application.compile_env(:realtime, Realtime.Repo)

    @valid_attrs %{
      external_id: "external_id",
      name: "localhost",
      extensions: [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => db_conf[:hostname],
            "db_name" => db_conf[:database],
            "db_user" => db_conf[:username],
            "db_password" => db_conf[:password],
            "db_port" => "5432",
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
      external_id: "external_id",
      jwt_secret: "some updated jwt_secret",
      name: "some updated name"
    }
    @invalid_attrs %{external_id: nil, jwt_secret: nil, name: nil}

    def tenant_fixture(attrs \\ %{}) do
      {:ok, tenant} =
        attrs
        |> Enum.into(@valid_attrs)
        |> Api.create_tenant()

      tenant
    end

    test "list_tenants/0 returns all tenants" do
      tenant = tenant_fixture()

      assert Api.list_tenants() |> Enum.filter(fn e -> e.external_id == "external_id" end) == [
               tenant
             ]
    end

    test "get_tenant!/1 returns the tenant with given id" do
      tenant = tenant_fixture()

      assert Api.get_tenant!(tenant.id) |> Map.delete(:extensions) ==
               tenant |> Map.delete(:extensions)
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

    test "check get_tenant_by_external_id/1" do
      tenant_fixture()

      %Tenant{extensions: [%Extensions{} = extension]} =
        Api.get_tenant_by_external_id("external_id")

      assert Map.has_key?(extension.settings, "db_password")
      password = extension.settings["db_password"]
      assert ^password = "v1QVng3N+pZd/0AEObABwg=="
    end

    test "update_tenant/2 with valid data updates the tenant" do
      tenant = tenant_fixture()
      assert {:ok, %Tenant{} = tenant} = Api.update_tenant(tenant, @update_attrs)
      assert tenant.external_id == "external_id"

      assert tenant.jwt_secret ==
               Realtime.Helpers.encrypt!(
                 "some updated jwt_secret",
                 Application.get_env(:realtime, :db_enc_key)
               )

      assert tenant.name == "some updated name"
    end

    test "update_tenant/2 with invalid data returns error changeset" do
      tenant = tenant_fixture()
      assert {:error, %Ecto.Changeset{}} = Api.update_tenant(tenant, @invalid_attrs)
    end

    test "delete_tenant/1 deletes the tenant" do
      tenant = tenant_fixture()
      assert {:ok, %Tenant{}} = Api.delete_tenant(tenant)
      assert_raise Ecto.NoResultsError, fn -> Api.get_tenant!(tenant.id) end
    end

    test "delete_tenant_by_external_id/1 deletes the tenant" do
      tenant = tenant_fixture()
      assert true == Api.delete_tenant_by_external_id(tenant.external_id)
      assert false == Api.delete_tenant_by_external_id("undef_tenant")
      assert_raise Ecto.NoResultsError, fn -> Api.get_tenant!(tenant.id) end
    end

    test "change_tenant/1 returns a tenant changeset" do
      tenant = tenant_fixture()
      assert %Ecto.Changeset{} = Api.change_tenant(tenant)
    end

    test "list_extensions/1 " do
      assert length(Api.list_extensions()) == 1
    end

    test "preload_counters/1 " do
      tenant = tenant_fixture()
      assert Api.preload_counters(nil) == nil

      with_mocks([
        {GenCounter, [],
         [
           get: fn _ ->
             {:ok, 1}
           end
         ]},
        {RateCounter, [],
         [
           get: fn _ -> {:ok, %RateCounter{avg: 2}} end
         ]}
      ]) do
        counters = Api.preload_counters(tenant)
        assert counters.events_per_second_rolling == 2
        assert counters.events_per_second_now == 1
      end

      assert Api.preload_counters(nil, :any) == nil
    end

    test "rename_settings_field/2" do
      Api.rename_settings_field("poll_interval_ms", "poll_interval")
      assert %{extensions: [%{settings: %{"poll_interval" => _}}]} = tenant_fixture()
    end
  end
end
