defmodule Realtime.ApiTest do
  use Realtime.DataCase

  alias Realtime.Api

  describe "tenants" do
    alias Realtime.Api.Tenant

    @valid_attrs %{
      external_id: "some external_id",
      jwt_secret: "some jwt_secret",
      name: "some name"
    }
    @update_attrs %{
      external_id: "some updated external_id",
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
      assert Api.list_tenants() == [tenant]
    end

    test "get_tenant!/1 returns the tenant with given id" do
      tenant = tenant_fixture()
      assert Api.get_tenant!(tenant.id) == tenant
    end

    test "create_tenant/1 with valid data creates a tenant" do
      assert {:ok, %Tenant{} = tenant} = Api.create_tenant(@valid_attrs)
      assert tenant.external_id == "some external_id"
      assert tenant.jwt_secret == "some jwt_secret"
      assert tenant.name == "some name"
    end

    test "create_tenant/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Api.create_tenant(@invalid_attrs)
    end

    test "update_tenant/2 with valid data updates the tenant" do
      tenant = tenant_fixture()
      assert {:ok, %Tenant{} = tenant} = Api.update_tenant(tenant, @update_attrs)
      assert tenant.external_id == "some updated external_id"
      assert tenant.jwt_secret == "some updated jwt_secret"
      assert tenant.name == "some updated name"
    end

    test "update_tenant/2 with invalid data returns error changeset" do
      tenant = tenant_fixture()
      assert {:error, %Ecto.Changeset{}} = Api.update_tenant(tenant, @invalid_attrs)
      assert tenant == Api.get_tenant!(tenant.id)
    end

    test "delete_tenant/1 deletes the tenant" do
      tenant = tenant_fixture()
      assert {:ok, %Tenant{}} = Api.delete_tenant(tenant)
      assert_raise Ecto.NoResultsError, fn -> Api.get_tenant!(tenant.id) end
    end

    test "change_tenant/1 returns a tenant changeset" do
      tenant = tenant_fixture()
      assert %Ecto.Changeset{} = Api.change_tenant(tenant)
    end
  end
end
