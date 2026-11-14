defmodule Realtime.Tenants.PolicyEvalCacheTest do
  # The per-tenant, per-node cache around Realtime.Tenants.PolicyEvalLoader.
  use RealtimeWeb.ConnCase, async: true
  use Mimic

  setup :set_mimic_from_context

  alias Realtime.Tenants.PolicyEvalCache
  alias Realtime.Tenants.PolicyEvalCache.Entry
  alias Realtime.Tenants.PolicyEvalLoader
  alias Realtime.Tenants.PolicyEvalProfile

  setup [:checkout_tenant_and_connect]

  defp unique_tenant_id, do: "tenant_#{System.unique_integer([:positive])}"

  describe "fetch/2" do
    test "returns the same snapshot the loader would, on a real tenant database", %{
      db_conn: db_conn,
      tenant: tenant
    } do
      Enum.each(PolicyEvalPolicies.user_channel_policies(:plain), &Postgrex.query!(db_conn, &1, []))

      assert {:ok, loaded} = PolicyEvalLoader.load(db_conn, tenant.external_id)
      assert {:ok, cached} = PolicyEvalCache.fetch(db_conn, tenant.external_id)

      assert cached.snapshot == loaded
    end

    test "only loads once across repeated fetches for the same tenant" do
      tenant_id = unique_tenant_id()

      snapshot =
        PolicyEval.Snapshot.new(
          %{rls_enabled: true, rls_forced: false, roles: %{}, policies: []},
          PolicyEvalProfile.profile()
        )

      expect(PolicyEvalLoader, :load, 1, fn :fake_conn, ^tenant_id -> {:ok, snapshot} end)

      assert {:ok, %Entry{snapshot: ^snapshot, load_reason: :ttl}} = PolicyEvalCache.fetch(:fake_conn, tenant_id)
      assert {:ok, %Entry{snapshot: ^snapshot, load_reason: :ttl}} = PolicyEvalCache.fetch(:fake_conn, tenant_id)
      assert {:ok, %Entry{snapshot: ^snapshot, load_reason: :ttl}} = PolicyEvalCache.fetch(:fake_conn, tenant_id)
    end

    test "a load failure isn't cached, so the next fetch tries again" do
      tenant_id = unique_tenant_id()

      snapshot =
        PolicyEval.Snapshot.new(
          %{rls_enabled: true, rls_forced: false, roles: %{}, policies: []},
          PolicyEvalProfile.profile()
        )

      expect(PolicyEvalLoader, :load, fn :fake_conn, ^tenant_id -> {:error, :boom} end)
      assert {:error, :boom} = PolicyEvalCache.fetch(:fake_conn, tenant_id)

      expect(PolicyEvalLoader, :load, fn :fake_conn, ^tenant_id -> {:ok, snapshot} end)
      assert {:ok, %Entry{snapshot: ^snapshot, load_reason: :ttl}} = PolicyEvalCache.fetch(:fake_conn, tenant_id)
    end
  end

  describe "invalidate/1" do
    test "forces the next fetch to reload" do
      tenant_id = unique_tenant_id()

      snapshot =
        PolicyEval.Snapshot.new(
          %{rls_enabled: true, rls_forced: false, roles: %{}, policies: []},
          PolicyEvalProfile.profile()
        )

      expect(PolicyEvalLoader, :load, 2, fn :fake_conn, ^tenant_id -> {:ok, snapshot} end)

      assert {:ok, %Entry{snapshot: ^snapshot, load_reason: :ttl}} = PolicyEvalCache.fetch(:fake_conn, tenant_id)
      assert :ok = PolicyEvalCache.invalidate(tenant_id)
      assert {:ok, %Entry{snapshot: ^snapshot, load_reason: :ttl}} = PolicyEvalCache.fetch(:fake_conn, tenant_id)
    end
  end

  # Two snapshots that differ, to tell the cached one from the reloaded one.
  defp old_and_new_snapshots do
    profile = PolicyEvalProfile.profile()
    old = PolicyEval.Snapshot.new(%{rls_enabled: true, rls_forced: false, roles: %{}, policies: []}, profile)
    new = PolicyEval.Snapshot.new(%{rls_enabled: false, rls_forced: false, roles: %{}, policies: []}, profile)
    {old, new}
  end

  describe "reload/3" do
    test "replaces the cached entry with a fresh :mismatch one" do
      tenant_id = unique_tenant_id()
      {old, new} = old_and_new_snapshots()
      expect(PolicyEvalLoader, :load, fn :fake_conn, ^tenant_id -> {:ok, old} end)
      assert {:ok, stale} = PolicyEvalCache.fetch(:fake_conn, tenant_id)

      expect(PolicyEvalLoader, :load, fn :fake_conn, ^tenant_id -> {:ok, new} end)

      assert {:ok, %Entry{snapshot: ^new, load_reason: :mismatch} = fresh} =
               PolicyEvalCache.reload(:fake_conn, tenant_id, stale)

      assert {:ok, ^fresh} = PolicyEvalCache.fetch(:fake_conn, tenant_id)
    end

    test "callers with the same stale entry share one load" do
      tenant_id = unique_tenant_id()
      {old, new} = old_and_new_snapshots()
      expect(PolicyEvalLoader, :load, fn :fake_conn, ^tenant_id -> {:ok, old} end)
      assert {:ok, stale} = PolicyEvalCache.fetch(:fake_conn, tenant_id)

      # A second load would fail the expectation. Whether a caller waits on the running load or gets
      # the finished one is Cachex's business; one load is the guarantee.
      expect(PolicyEvalLoader, :load, 1, fn :fake_conn, ^tenant_id -> {:ok, new} end)

      tasks = for _ <- 1..5, do: Task.async(fn -> PolicyEvalCache.reload(:fake_conn, tenant_id, stale) end)

      [first | _] = results = Task.await_many(tasks)
      assert {:ok, %Entry{snapshot: ^new, load_reason: :mismatch}} = first
      assert Enum.uniq(results) == [first]

      assert PolicyEvalCache.reload(:fake_conn, tenant_id, stale) == first
    end

    test "a failed load replaces nothing and isn't cached" do
      tenant_id = unique_tenant_id()
      {old, new} = old_and_new_snapshots()
      expect(PolicyEvalLoader, :load, fn :fake_conn, ^tenant_id -> {:ok, old} end)
      assert {:ok, stale} = PolicyEvalCache.fetch(:fake_conn, tenant_id)

      expect(PolicyEvalLoader, :load, fn :fake_conn, ^tenant_id -> {:error, :boom} end)
      assert {:error, :boom} = PolicyEvalCache.reload(:fake_conn, tenant_id, stale)
      assert {:ok, ^stale} = PolicyEvalCache.fetch(:fake_conn, tenant_id)

      expect(PolicyEvalLoader, :load, fn :fake_conn, ^tenant_id -> {:ok, new} end)

      assert {:ok, %Entry{snapshot: ^new, load_reason: :mismatch}} =
               PolicyEvalCache.reload(:fake_conn, tenant_id, stale)
    end
  end
end
