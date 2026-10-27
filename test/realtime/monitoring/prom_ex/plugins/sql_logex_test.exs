defmodule Realtime.PromEx.Plugins.SqlLogexTest do
  # The metrics have no tenant tag, so every test in this module shares the same series: each test
  # reads the value before acting and asserts on the difference, rather than on an absolute count.
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

  defp metric_value(metric, expected_tags \\ nil) do
    MetricsHelper.search(PromEx.get_metrics(MetricsTest), metric, expected_tags) || 0
  end

  test "counts a matching read decision and records shadow duration, without a tenant tag" do
    tenant_id = random_string()
    expect(FeatureFlags, :enabled?, fn "sql_logex_shadow", ^tenant_id -> true end)
    expect(SqlLogexCache, :fetch, fn :fake_conn, ^tenant_id -> {:ok, always_allow_snapshot()} end)

    decision = "realtime_tenants_sql_logex_shadow_read_decisions_total"
    duration = "realtime_tenants_sql_logex_shadow_read_shadow_duration_count"
    tags = [outcome: "match", extension: "broadcast", reason: "none"]
    decisions_before = metric_value(decision, tags)
    durations_before = metric_value(duration)

    result = {:ok, %Policies{broadcast: %BroadcastPolicies{read: true}}}
    assert :ok = SqlLogexShadow.read(:fake_conn, context(tenant_id), [:broadcast], result)

    assert_eventually metric_value(decision, tags) == decisions_before + 1
    assert_eventually metric_value(duration) == durations_before + 1
    refute PromEx.get_metrics(MetricsTest) |> IO.iodata_to_binary() =~ tenant_id
  end

  test "tags a fallback with the category of its reason" do
    tenant_id = random_string()
    expect(FeatureFlags, :enabled?, fn "sql_logex_shadow", ^tenant_id -> true end)
    expect(SqlLogexCache, :fetch, fn :fake_conn, ^tenant_id -> {:ok, always_allow_snapshot()} end)

    decision = "realtime_tenants_sql_logex_shadow_read_decisions_total"
    tags = [outcome: "fallback", extension: "broadcast", reason: "role"]
    before = metric_value(decision, tags)

    # service_role isn't a role sql_logex models, so it falls back with {:role, "service_role"}
    ctx = %{context(tenant_id) | role: "service_role", claims: %{"role" => "service_role"}}
    result = {:ok, %Policies{broadcast: %BroadcastPolicies{read: true}}}
    assert :ok = SqlLogexShadow.read(:fake_conn, ctx, [:broadcast], result)

    assert_eventually metric_value(decision, tags) == before + 1
  end

  test "broadcast and presence decisions are counted as separate series" do
    tenant_id = random_string()
    expect(FeatureFlags, :enabled?, fn "sql_logex_shadow", ^tenant_id -> true end)
    expect(SqlLogexCache, :fetch, fn :fake_conn, ^tenant_id -> {:ok, always_allow_snapshot()} end)

    decision = "realtime_tenants_sql_logex_shadow_read_decisions_total"
    broadcast_tags = [outcome: "match", extension: "broadcast"]
    presence_tags = [outcome: "mismatch", extension: "presence"]
    broadcast_before = metric_value(decision, broadcast_tags)
    presence_before = metric_value(decision, presence_tags)

    result = {:ok, %Policies{broadcast: %BroadcastPolicies{read: true}, presence: %PresencePolicies{read: false}}}
    assert :ok = SqlLogexShadow.read(:fake_conn, context(tenant_id), [:broadcast, :presence], result)

    assert_eventually metric_value(decision, broadcast_tags) == broadcast_before + 1
    assert_eventually metric_value(decision, presence_tags) == presence_before + 1
  end

  test "counts an unavailable snapshot" do
    tenant_id = random_string()
    expect(FeatureFlags, :enabled?, fn "sql_logex_shadow", ^tenant_id -> true end)
    expect(SqlLogexCache, :fetch, fn :fake_conn, ^tenant_id -> {:error, :boom} end)

    unavailable = "realtime_tenants_sql_logex_shadow_write_unavailable_total"
    before = metric_value(unavailable)

    assert :ok = SqlLogexShadow.write(:fake_conn, context(tenant_id), [:broadcast], {:ok, %Policies{}})

    assert_eventually metric_value(unavailable) == before + 1
  end
end
