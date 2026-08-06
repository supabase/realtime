start_time = :os.system_time(:millisecond)

alias Realtime.Api

# External-tenant-db mode (USE_EXTERNAL_TENANT_DB=true): each configured
# port is an independent DB reused across the whole run, so max_cases must
# equal the number of configured ports exactly, not just be <= it —
# oversubscribing beyond the port count causes far worse, cascading
# failures than running serially (concurrent tenant setup, e.g. DROP SCHEMA
# realtime CASCADE, stomping on each other once demand exceeds supply).
# max_cases is therefore forced here rather than read from MAX_CASES.
max_cases =
  if Containers.external_tenant_db?() do
    forced_max_cases = length(Containers.external_tenant_db_ports!())

    if System.get_env("MAX_CASES") do
      IO.puts(
        "[test_helper.exs] USE_EXTERNAL_TENANT_DB=true: ignoring MAX_CASES, forcing " <>
          "max_cases to #{forced_max_cases} (the number of configured external ports)."
      )
    end

    forced_max_cases
  else
    String.to_integer(System.get_env("MAX_CASES", "4"))
  end

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

ExUnit.start(
  exclude: exclude,
  max_cases: max_cases,
  capture_log: Realtime.Env.get_boolean("CAPTURE_LOG", true)
)

max_cases = ExUnit.configuration()[:max_cases]

# In external mode no supabase/postgres image is used, so skip the pull and
# the container teardown. The Containers GenServer still starts (tests call
# Containers.port()), but its eager poolboy pool is skipped (see
# handle_continue in containers.ex).
unless Containers.external_tenant_db?() do
  Containers.pull()

  if System.get_env("REUSE_CONTAINERS") != "true" do
    Containers.stop_containers()
  end
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
Mimic.copy(Forum.Muster)
Mimic.copy(Realtime.Database)
Mimic.copy(Realtime.FeatureFlags)
Mimic.copy(Realtime.GenCounter)
Mimic.copy(Realtime.GenRpc)
Mimic.copy(Realtime.Nodes)
Mimic.copy(Realtime.Repo)
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
