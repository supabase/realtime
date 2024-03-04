defmodule Realtime.Tenants.CacheTest do
  use Realtime.DataCase

  alias Realtime.Api
  alias Realtime.Tenants

  setup do
    %{tenant: tenant_fixture()}
  end

  describe "get_tenant_by_external_id/1" do
    test "tenants cache returns a cached result", %{tenant: tenant} do
      external_id = tenant.external_id

      assert %Api.Tenant{name: "localhost"} = Tenants.Cache.get_tenant_by_external_id(external_id)

      Api.update_tenant(tenant, %{name: "new name"})

      assert %Api.Tenant{name: "new name"} = Tenants.get_tenant_by_external_id(external_id)

      assert %Api.Tenant{name: "localhost"} = Tenants.Cache.get_tenant_by_external_id(external_id)
    end
  end

  describe "invalidate_tenant_cache/1" do
    test "invalidates the cache given a tenant_id", %{tenant: tenant} do
      external_id = tenant.external_id
      assert %Api.Tenant{suspend: false} = Tenants.Cache.get_tenant_by_external_id(external_id)

      # Update a tenant
      tenant |> Realtime.Api.Tenant.changeset(%{suspend: true}) |> Realtime.Repo.update!()

      # Cache showing old value
      assert %Api.Tenant{suspend: false} = Tenants.Cache.get_tenant_by_external_id(external_id)

      # Invalidate cache
      Tenants.Cache.invalidate_tenant_cache(external_id)
      assert %Api.Tenant{suspend: true} = Tenants.Cache.get_tenant_by_external_id(external_id)
    end
  end

  describe "distributed_invalidate_tenant_cache/1" do
    test "invalidates the cache given a tenant_id", %{tenant: tenant} do
      external_id = tenant.external_id
      assert %Api.Tenant{suspend: false} = Tenants.Cache.get_tenant_by_external_id(external_id)

      # Delete tenant
      Realtime.Repo.delete(tenant)

      # Cache showing non existing tenant
      assert %Api.Tenant{suspend: false} = Tenants.Cache.get_tenant_by_external_id(external_id)

      # Invalidate cache
      Tenants.Cache.distributed_invalidate_tenant_cache(external_id)
      :timer.sleep(500)
      refute Tenants.Cache.get_tenant_by_external_id(external_id)
    end
  end
end
