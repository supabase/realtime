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

# Restriction assertions on the postgres role only when supautils.policy_grants includes realtime.messages and realtime.subscription (supabase/postgres >= 15.14.1.018)
requires_supautils_policy_grants = if !has_supautils_realtime_grants, do: :requires_supautils_policy_grants
requires_no_supautils_policy_grants = if has_supautils_realtime_grants, do: :requires_no_supautils_policy_grants

skip_orioledb = if orioledb?, do: :skip_orioledb

exclude =
  Enum.reject(
    [
      :failing,
      requires_pg_140006,
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

Mimic.copy(:syn)
Mimic.copy(Cachex)
Mimic.copy(Ecto.Migrator)
Mimic.copy(Extensions.PostgresCdcRls)
Mimic.copy(Extensions.PostgresCdcRls.Replications)
Mimic.copy(Extensions.PostgresCdcRls.Subscriptions)
Mimic.copy(Realtime.Database)
Mimic.copy(Realtime.FeatureFlags)
Mimic.copy(Realtime.GenCounter)
Mimic.copy(Realtime.GenRpc)
Mimic.copy(Realtime.Nodes)
Mimic.copy(Realtime.Repo.Replica)
Mimic.copy(Realtime.RateCounter)
Mimic.copy(Realtime.Tenants.Authorization)
Mimic.copy(Realtime.Tenants.Cache)
Mimic.copy(Realtime.Tenants.Repo)
Mimic.copy(Realtime.Tenants.Connect)
Mimic.copy(Realtime.Tenants.Migrations)
Mimic.copy(Realtime.Tenants.Rebalancer)
Mimic.copy(Realtime.Tenants.ReplicationConnection)
Mimic.copy(Realtime.UsersCounter)
Mimic.copy(RealtimeWeb.ChannelsAuthorization)
Mimic.copy(RealtimeWeb.Endpoint)
Mimic.copy(RealtimeWeb.JwtVerification)
Mimic.copy(RealtimeWeb.TenantBroadcaster)
Mimic.copy(NimbleZTA.Cloudflare)

partition = System.get_env("MIX_TEST_PARTITION")
node_name = if partition, do: :"main#{partition}@127.0.0.1", else: :"main@127.0.0.1"
:net_kernel.start([node_name])
region = Application.get_env(:realtime, :region)
[{pid, _}] = :syn.members(RegionNodes, region)
:syn.update_member(RegionNodes, region, pid, fn _ -> [node: node()] end)

end_time = :os.system_time(:millisecond)
IO.puts("[test_helper.exs] Time to start tests: #{end_time - start_time} ms")
