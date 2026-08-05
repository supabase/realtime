start_time = :os.system_time(:millisecond)

alias Realtime.Api
max_cases = String.to_integer(System.get_env("MAX_CASES", "4"))

repo_config = Application.fetch_env!(:realtime, Realtime.Repo)

{:ok, pg_conn} =
  Postgrex.start_link(
    hostname: repo_config[:hostname],
    port: repo_config[:port] || 5432,
    username: repo_config[:username],
    password: repo_config[:password],
    database: "postgres"
  )

%{rows: [[pg_version_num]]} = Postgrex.query!(pg_conn, "SELECT current_setting('server_version_num')::int")

%{rows: [[has_supautils_realtime_grants]]} =
  Postgrex.query!(
    pg_conn,
    "SELECT current_setting('supautils.policy_grants', true) LIKE '%realtime.messages%' AND current_setting('supautils.policy_grants', true) LIKE '%realtime.subscription%'"
  )

%{rows: [[orioledb?]]} =
  Postgrex.query!(pg_conn, "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'orioledb')")

# `realtime.broadcast_changes(..., NEW record, OLD record, ...)` (introduced in commit 2922658c) called from a trigger via `PERFORM` fails on PG <= 14.5
requires_pg_140006 = if pg_version_num < 140_006, do: :requires_pg_140006

requires_pg_150000 = if pg_version_num < 150_000, do: :requires_pg_150000

# Restriction assertions on the postgres role only when supautils.policy_grants includes realtime.messages and realtime.subscription (supabase/postgres >= 15.14.1.018)
requires_supautils_policy_grants = if !has_supautils_realtime_grants, do: :requires_supautils_policy_grants
requires_no_supautils_policy_grants = if has_supautils_realtime_grants, do: :requires_no_supautils_policy_grants

skip_orioledb = if orioledb?, do: :skip_orioledb

exclude =
  Enum.reject(
    [
      :failing,
      requires_pg_140006,
      requires_pg_150000,
      requires_supautils_policy_grants,
      requires_no_supautils_policy_grants,
      skip_orioledb
    ],
    &is_nil/1
  )

ExUnit.start(exclude: exclude, max_cases: max_cases, capture_log: true)

max_cases = ExUnit.configuration()[:max_cases]

Containers.pull()

if System.get_env("REUSE_CONTAINERS") != "true" do
  Containers.stop_containers()
end

{:ok, _pid} = Containers.start_link(max_cases)

for tenant <- Api.list_tenants(), do: Api.delete_tenant_by_external_id(tenant.external_id)

Ecto.Adapters.SQL.Sandbox.mode(Realtime.Repo, :manual)

Mimic.copy(:syn, type_check: true)
Mimic.copy(Cachex, type_check: true)
Mimic.copy(Ecto.Migrator, type_check: true)
Mimic.copy(Extensions.PostgresCdcRls, type_check: true)
Mimic.copy(Extensions.PostgresCdcRls.Replications, type_check: true)
Mimic.copy(Extensions.PostgresCdcRls.Subscriptions, type_check: true)
Mimic.copy(Forum.Muster, type_check: true)
Mimic.copy(Realtime.Database, type_check: true)
Mimic.copy(Realtime.FeatureFlags, type_check: true)
Mimic.copy(Realtime.GenCounter, type_check: true)
Mimic.copy(Realtime.GenRpc, type_check: true)
Mimic.copy(Realtime.Nodes, type_check: true)
Mimic.copy(Realtime.Repo, type_check: true)
Mimic.copy(Realtime.Repo.Replica, type_check: true)
Mimic.copy(Realtime.RateCounter, type_check: true)
Mimic.copy(Realtime.Tenants.Authorization, type_check: true)
Mimic.copy(Realtime.Tenants.Cache, type_check: true)
Mimic.copy(Realtime.Tenants.Repo, type_check: true)
Mimic.copy(Realtime.Tenants.Connect, type_check: true)
Mimic.copy(Realtime.Tenants.Migrations, type_check: true)
Mimic.copy(Realtime.Tenants.Rebalancer, type_check: true)
Mimic.copy(Realtime.Tenants.ReplicationConnection, type_check: true)
Mimic.copy(Realtime.UsersCounter, type_check: true)
Mimic.copy(RealtimeWeb.ChannelsAuthorization, type_check: true)
Mimic.copy(RealtimeWeb.Endpoint, type_check: true)
Mimic.copy(RealtimeWeb.JwtVerification, type_check: true)
Mimic.copy(RealtimeWeb.TenantBroadcaster, type_check: true)
Mimic.copy(NimbleZTA.Cloudflare, type_check: true)

partition = System.get_env("MIX_TEST_PARTITION")
node_name = if partition, do: :"main#{partition}@127.0.0.1", else: :"main@127.0.0.1"
:net_kernel.start([node_name])
region = Application.get_env(:realtime, :region)
[{pid, _}] = :syn.members(RegionNodes, region)
:syn.update_member(RegionNodes, region, pid, fn _ -> [node: node()] end)

end_time = :os.system_time(:millisecond)
IO.puts("[test_helper.exs] Time to start tests: #{end_time - start_time} ms")
