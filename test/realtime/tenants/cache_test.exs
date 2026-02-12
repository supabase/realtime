defmodule Realtime.Tenants.CacheTest do
  use Realtime.DataCase, async: false

  alias Realtime.Api
  alias Realtime.Rpc
  alias Realtime.Tenants
  alias Realtime.Tenants.Cache

  setup do
    {:ok, tenant: tenant_fixture()}
  end

  describe "get_tenant_by_external_id/1" do
    test "tenants cache returns a cached result", %{tenant: tenant} do
      external_id = tenant.external_id
      assert %Api.Tenant{name: "tenant"} = Cache.get_tenant_by_external_id(external_id)

      changeset = Api.Tenant.changeset(tenant, %{name: "new name"})
      Repo.update!(changeset)
      assert %Api.Tenant{name: "new name"} = Tenants.get_tenant_by_external_id(external_id)
      assert %Api.Tenant{name: "tenant"} = Cache.get_tenant_by_external_id(external_id)
    end

    test "does not cache when tenant is not found" do
      assert Cache.get_tenant_by_external_id("not found") == nil

      assert Cachex.exists?(Cache, {:get_tenant_by_external_id, "not found"}) == {:ok, false}
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

  describe "update_cache/1" do
    test "updates the cache given a tenant", %{tenant: tenant} do
      external_id = tenant.external_id
      assert %Api.Tenant{name: "tenant"} = Cache.get_tenant_by_external_id(external_id)
      # Update a tenant
      updated_tenant = %{tenant | name: "updated name"}
      # Update cache
      Cache.update_cache(updated_tenant)
      assert %Api.Tenant{name: "updated name"} = Cache.get_tenant_by_external_id(external_id)
    end
  end

  describe "distributed_invalidate_tenant_cache/1" do
    setup do
      {:ok, node} = Clustered.start()

      tenant =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Realtime.Repo, fn ->
          tenant_fixture()
        end)

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Realtime.Repo, fn ->
          Realtime.Api.delete_tenant_by_external_id(tenant.external_id)
        end)
      end)

      %{node: node, tenant: tenant}
    end

    test "invalidates the cache given a tenant_id", %{node: node, tenant: tenant} do
      external_id = tenant.external_id
      expected_name = tenant.name
      dummy_name = random_string()
      dummy_tenant = %{tenant | name: dummy_name}

      assert {:ok, true} = Cache.update_cache(dummy_tenant)

      assert {:ok, %Api.Tenant{name: ^dummy_name}} =
               Cachex.get(Cache, {:get_tenant_by_external_id, external_id})

      seed_remote_cache(node, external_id, dummy_tenant)

      assert :ok = Cache.distributed_invalidate_tenant_cache(external_id)

      assert_eventually(fn ->
        %Api.Tenant{name: ^expected_name} = Cache.get_tenant_by_external_id(external_id)

        %Api.Tenant{name: ^expected_name} =
          Rpc.enhanced_call(node, Cache, :get_tenant_by_external_id, [external_id])
      end)
    end
  end

  describe "global_cache_update/1" do
    setup do
      {:ok, node} = Clustered.start()

      tenant =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Realtime.Repo, fn ->
          tenant_fixture()
        end)

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Realtime.Repo, fn ->
          Realtime.Api.delete_tenant_by_external_id(tenant.external_id)
        end)
      end)

      %{node: node, tenant: tenant}
    end

    test "update the cache given a tenant_id", %{node: node, tenant: tenant} do
      external_id = tenant.external_id
      expected_name = tenant.name
      dummy_name = random_string()
      dummy_tenant = %{tenant | name: dummy_name}

      assert {:ok, true} = Cache.update_cache(dummy_tenant)

      assert {:ok, %Api.Tenant{name: ^dummy_name}} =
               Cachex.get(Cache, {:get_tenant_by_external_id, external_id})

      seed_remote_cache(node, external_id, dummy_tenant)

      assert :ok = Cache.global_cache_update(tenant)

      assert_eventually(fn ->
        {:ok, %Api.Tenant{name: ^expected_name}} =
          Cachex.get(Cache, {:get_tenant_by_external_id, external_id})

        {:ok, %Api.Tenant{name: ^expected_name}} =
          Rpc.enhanced_call(node, Cachex, :get, [Cache, {:get_tenant_by_external_id, external_id}])
      end)
    end
  end

  defp seed_remote_cache(node, external_id, tenant, attempts \\ 20) do
    Rpc.enhanced_call(node, Cache, :update_cache, [tenant])

    case Rpc.enhanced_call(node, Cachex, :get, [Cache, {:get_tenant_by_external_id, external_id}]) do
      {:ok, %Api.Tenant{external_id: ^external_id, name: name}} when name == tenant.name ->
        :ok

      _other when attempts > 0 ->
        Process.sleep(50)
        seed_remote_cache(node, external_id, tenant, attempts - 1)

      other ->
        flunk("Failed to seed remote cache after retries, last result: #{inspect(other)}")
    end
  end

  defp assert_eventually(fun, attempts \\ 50, interval \\ 100)

  defp assert_eventually(fun, 0, _interval) do
    fun.()
  end

  defp assert_eventually(fun, attempts, interval) do
    fun.()
  rescue
    _ ->
      Process.sleep(interval)
      assert_eventually(fun, attempts - 1, interval)
  end
end
