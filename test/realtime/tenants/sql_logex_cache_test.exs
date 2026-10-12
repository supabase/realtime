defmodule Realtime.Tenants.SqlLogexCacheTest do
  # The per-tenant, per-node cache around Realtime.Tenants.SqlLogexLoader.
  use RealtimeWeb.ConnCase, async: true
  use Mimic

  setup :set_mimic_from_context

  alias Realtime.Tenants.SqlLogexCache
  alias Realtime.Tenants.SqlLogexLoader

  setup [:checkout_tenant_and_connect]

  describe "fetch/2" do
    test "returns the same snapshot the loader would, on a real tenant database", %{
      db_conn: db_conn,
      tenant: tenant
    } do
      Enum.each(SqlLogexPolicies.user_channel_policies(:plain), &Postgrex.query!(db_conn, &1, []))

      assert {:ok, loaded} = SqlLogexLoader.load(db_conn, tenant.external_id)
      assert {:ok, cached} = SqlLogexCache.fetch(db_conn, tenant.external_id)

      assert cached == loaded
    end

    test "only loads once across repeated fetches for the same tenant" do
      tenant_id = "tenant_#{System.unique_integer([:positive])}"
      snapshot = SqlLogex.Snapshot.new(%{rls_enabled: true, rls_forced: false, roles: %{}, policies: []})

      expect(SqlLogexLoader, :load, 1, fn :fake_conn, ^tenant_id -> {:ok, snapshot} end)

      assert {:ok, ^snapshot} = SqlLogexCache.fetch(:fake_conn, tenant_id)
      assert {:ok, ^snapshot} = SqlLogexCache.fetch(:fake_conn, tenant_id)
      assert {:ok, ^snapshot} = SqlLogexCache.fetch(:fake_conn, tenant_id)
    end

    test "a load failure isn't cached, so the next fetch tries again" do
      tenant_id = "tenant_#{System.unique_integer([:positive])}"
      snapshot = SqlLogex.Snapshot.new(%{rls_enabled: true, rls_forced: false, roles: %{}, policies: []})

      expect(SqlLogexLoader, :load, fn :fake_conn, ^tenant_id -> {:error, :boom} end)
      assert {:error, :boom} = SqlLogexCache.fetch(:fake_conn, tenant_id)

      expect(SqlLogexLoader, :load, fn :fake_conn, ^tenant_id -> {:ok, snapshot} end)
      assert {:ok, ^snapshot} = SqlLogexCache.fetch(:fake_conn, tenant_id)
    end
  end

  describe "invalidate/1" do
    test "forces the next fetch to reload" do
      tenant_id = "tenant_#{System.unique_integer([:positive])}"
      snapshot = SqlLogex.Snapshot.new(%{rls_enabled: true, rls_forced: false, roles: %{}, policies: []})

      expect(SqlLogexLoader, :load, 2, fn :fake_conn, ^tenant_id -> {:ok, snapshot} end)

      assert {:ok, ^snapshot} = SqlLogexCache.fetch(:fake_conn, tenant_id)
      assert :ok = SqlLogexCache.invalidate(tenant_id)
      assert {:ok, ^snapshot} = SqlLogexCache.fetch(:fake_conn, tenant_id)
    end
  end
end
