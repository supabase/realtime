defmodule Realtime.PromEx.Plugins.SqlLogexTest do
  use Realtime.DataCase, async: false
  use Mimic

  setup :set_mimic_from_context

  alias Realtime.FeatureFlags
  alias Realtime.PromEx.Plugins.SqlLogex, as: SqlLogexPlugin
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies
  alias Realtime.Tenants.SqlLogexCache
  alias Realtime.Tenants.SqlLogexShadow

  defmodule MetricsTest do
    use PromEx, otp_app: :realtime_test_sql_logex

    @impl true
    def plugins, do: [{SqlLogexPlugin, poll_rate: 50}]
  end

  setup_all do
    start_supervised!(MetricsTest)
    :ok
  end

  defp context(tenant_id) do
    Authorization.build_authorization_params(%{
      tenant_id: tenant_id,
      topic: "room:1",
      headers: [],
      claims: %{"role" => "authenticated"},
      role: "authenticated",
      sub: nil
    })
  end

  defp always_allow_snapshot do
    SqlLogex.Snapshot.new(%{
      rls_enabled: true,
      rls_forced: false,
      roles: %{"authenticated" => %{bypass_rls: false, select: true, insert: true}},
      policies: [%{name: "p", cmd: "*", permissive: true, roles: ["authenticated"], qual: "true", with_check: nil}]
    })
  end

  defp metric_value(metric, expected_tags) do
    MetricsHelper.search(PromEx.get_metrics(MetricsTest), metric, expected_tags)
  end

  test "counts a matching read decision and records shadow duration" do
    tenant_id = random_string()
    expect(FeatureFlags, :enabled?, fn "sql_logex_shadow", ^tenant_id -> true end)
    expect(SqlLogexCache, :fetch, fn :fake_conn, ^tenant_id -> {:ok, always_allow_snapshot()} end)

    result = {:ok, %Policies{broadcast: %BroadcastPolicies{read: true}}}
    assert :ok = SqlLogexShadow.read(:fake_conn, context(tenant_id), [:broadcast], result)

    assert_eventually metric_value("realtime_tenants_sql_logex_shadow_read_decisions_total",
                        tenant: tenant_id,
                        outcome: "match",
                        extension: "broadcast",
                        reason: "none"
                      ) == 1

    assert_eventually metric_value("realtime_tenants_sql_logex_shadow_read_shadow_duration_count", tenant: tenant_id) ==
                        1
  end

  test "tags a fallback with the category of its reason" do
    tenant_id = random_string()
    expect(FeatureFlags, :enabled?, fn "sql_logex_shadow", ^tenant_id -> true end)
    expect(SqlLogexCache, :fetch, fn :fake_conn, ^tenant_id -> {:ok, always_allow_snapshot()} end)

    # service_role isn't a role sql_logex models, so it falls back with {:role, "service_role"}
    ctx = %{context(tenant_id) | role: "service_role", claims: %{"role" => "service_role"}}
    result = {:ok, %Policies{broadcast: %BroadcastPolicies{read: true}}}
    assert :ok = SqlLogexShadow.read(:fake_conn, ctx, [:broadcast], result)

    assert_eventually metric_value("realtime_tenants_sql_logex_shadow_read_decisions_total",
                        tenant: tenant_id,
                        outcome: "fallback",
                        extension: "broadcast",
                        reason: "role"
                      ) == 1
  end

  test "broadcast and presence decisions are counted as separate series" do
    tenant_id = random_string()
    expect(FeatureFlags, :enabled?, fn "sql_logex_shadow", ^tenant_id -> true end)
    expect(SqlLogexCache, :fetch, fn :fake_conn, ^tenant_id -> {:ok, always_allow_snapshot()} end)

    result = {:ok, %Policies{broadcast: %BroadcastPolicies{read: true}, presence: %PresencePolicies{read: false}}}
    assert :ok = SqlLogexShadow.read(:fake_conn, context(tenant_id), [:broadcast, :presence], result)

    assert_eventually metric_value("realtime_tenants_sql_logex_shadow_read_decisions_total",
                        tenant: tenant_id,
                        outcome: "match",
                        extension: "broadcast"
                      ) == 1

    assert_eventually metric_value("realtime_tenants_sql_logex_shadow_read_decisions_total",
                        tenant: tenant_id,
                        outcome: "mismatch",
                        extension: "presence"
                      ) == 1
  end

  test "counts an unavailable snapshot" do
    tenant_id = random_string()
    expect(FeatureFlags, :enabled?, fn "sql_logex_shadow", ^tenant_id -> true end)
    expect(SqlLogexCache, :fetch, fn :fake_conn, ^tenant_id -> {:error, :boom} end)

    assert :ok = SqlLogexShadow.write(:fake_conn, context(tenant_id), [:broadcast], {:ok, %Policies{}})

    assert_eventually metric_value("realtime_tenants_sql_logex_shadow_write_unavailable_total", tenant: tenant_id) == 1
  end
end
