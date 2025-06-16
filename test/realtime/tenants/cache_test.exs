defmodule Realtime.Tenants.CacheTest do
  alias Realtime.Rpc
  # async: false due to the usage of dev_realtime tenant
  use Realtime.DataCase, async: false

  alias Realtime.Api
  alias Realtime.Tenants.Cache
  alias Realtime.Tenants

  setup do
    {:ok, tenant: tenant_fixture()}
  end

  describe "get_tenant_by_external_id/1" do
    test "tenants cache returns a cached result", %{tenant: tenant} do
      external_id = tenant.external_id
      assert %Api.Tenant{name: "tenant"} = Cache.get_tenant_by_external_id(external_id)
      Api.update_tenant(tenant, %{name: "new name"})
      assert %Api.Tenant{name: "new name"} = Tenants.get_tenant_by_external_id(external_id)
      assert %Api.Tenant{name: "tenant"} = Cache.get_tenant_by_external_id(external_id)
    end
  end

  describe "invalidate_tenant_cache/1" do
    test "invalidates the cache given a tenant_id", %{tenant: tenant} do
      external_id = tenant.external_id
      assert %Api.Tenant{suspend: false} = Cache.get_tenant_by_external_id(external_id)

      # Update a tenant
      tenant |> Realtime.Api.Tenant.changeset(%{suspend: true}) |> Realtime.Repo.update!()

      # Cache showing old value
      assert %Api.Tenant{suspend: false} = Cache.get_tenant_by_external_id(external_id)

      # Invalidate cache
      Cache.invalidate_tenant_cache(external_id)
      assert %Api.Tenant{suspend: true} = Cache.get_tenant_by_external_id(external_id)
    end
  end

  describe "distributed_invalidate_tenant_cache/1" do
    setup do
      {:ok, node} = Clustered.start()
      %{node: node}
    end

    test "invalidates the cache given a tenant_id", %{node: node} do
      external_id = "dev_tenant"
      %Api.Tenant{name: expected_name} = tenant = Tenants.get_tenant_by_external_id(external_id)

      dummy_name = random_string()

      # Ensure cache has the values
      Cachex.put!(
        Realtime.Tenants.Cache,
        {{:get_tenant_by_external_id, 1}, [external_id]},
        {:cached, %{tenant | name: dummy_name}}
      )

      Rpc.enhanced_call(node, Cachex, :put!, [
        Realtime.Tenants.Cache,
        {{:get_tenant_by_external_id, 1}, [external_id]},
        {:cached, %{tenant | name: dummy_name}}
      ])

      # Cache showing old value
      assert %Api.Tenant{name: ^dummy_name} = Cache.get_tenant_by_external_id(external_id)
      assert %Api.Tenant{name: ^dummy_name} = Rpc.enhanced_call(node, Cache, :get_tenant_by_external_id, [external_id])

      # Invalidate cache
      assert true = Cache.distributed_invalidate_tenant_cache(external_id)

      # Cache showing new value
      assert %Api.Tenant{name: ^expected_name} = Cache.get_tenant_by_external_id(external_id)

      assert %Api.Tenant{name: ^expected_name} =
               Rpc.enhanced_call(node, Cache, :get_tenant_by_external_id, [external_id])
    end
  end
end
