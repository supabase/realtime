defmodule Realtime.Tenants.PolicyEvalCacheTest do
  # The per-tenant, per-node cache around Realtime.Tenants.PolicyEvalLoader.
  use RealtimeWeb.ConnCase, async: true
  use Mimic

  setup :set_mimic_from_context

  alias Realtime.Tenants.PolicyEvalCache
  alias Realtime.Tenants.PolicyEvalLoader
  alias Realtime.Tenants.PolicyEvalProfile

  setup [:checkout_tenant_and_connect]

  describe "fetch/2" do
    test "returns the same snapshot the loader would, on a real tenant database", %{
      db_conn: db_conn,
      tenant: tenant
    } do
      Enum.each(PolicyEvalPolicies.user_channel_policies(:plain), &Postgrex.query!(db_conn, &1, []))

      assert {:ok, loaded} = PolicyEvalLoader.load(db_conn, tenant.external_id)
      assert {:ok, cached} = PolicyEvalCache.fetch(db_conn, tenant.external_id)

      assert cached == loaded
    end

    test "only loads once across repeated fetches for the same tenant" do
      tenant_id = "tenant_#{System.unique_integer([:positive])}"

      snapshot =
        PolicyEval.Snapshot.new(
          %{rls_enabled: true, rls_forced: false, roles: %{}, policies: []},
          PolicyEvalProfile.profile()
        )

      expect(PolicyEvalLoader, :load, 1, fn :fake_conn, ^tenant_id -> {:ok, snapshot} end)

      assert {:ok, ^snapshot} = PolicyEvalCache.fetch(:fake_conn, tenant_id)
      assert {:ok, ^snapshot} = PolicyEvalCache.fetch(:fake_conn, tenant_id)
      assert {:ok, ^snapshot} = PolicyEvalCache.fetch(:fake_conn, tenant_id)
    end

    test "a load failure isn't cached, so the next fetch tries again" do
      tenant_id = "tenant_#{System.unique_integer([:positive])}"

      snapshot =
        PolicyEval.Snapshot.new(
          %{rls_enabled: true, rls_forced: false, roles: %{}, policies: []},
          PolicyEvalProfile.profile()
        )

      expect(PolicyEvalLoader, :load, fn :fake_conn, ^tenant_id -> {:error, :boom} end)
      assert {:error, :boom} = PolicyEvalCache.fetch(:fake_conn, tenant_id)

      expect(PolicyEvalLoader, :load, fn :fake_conn, ^tenant_id -> {:ok, snapshot} end)
      assert {:ok, ^snapshot} = PolicyEvalCache.fetch(:fake_conn, tenant_id)
    end
  end

  describe "invalidate/1" do
    test "forces the next fetch to reload" do
      tenant_id = "tenant_#{System.unique_integer([:positive])}"

      snapshot =
        PolicyEval.Snapshot.new(
          %{rls_enabled: true, rls_forced: false, roles: %{}, policies: []},
          PolicyEvalProfile.profile()
        )

      expect(PolicyEvalLoader, :load, 2, fn :fake_conn, ^tenant_id -> {:ok, snapshot} end)

      assert {:ok, ^snapshot} = PolicyEvalCache.fetch(:fake_conn, tenant_id)
      assert :ok = PolicyEvalCache.invalidate(tenant_id)
      assert {:ok, ^snapshot} = PolicyEvalCache.fetch(:fake_conn, tenant_id)
    end
  end
end
