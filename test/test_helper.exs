start_time = :os.system_time(:millisecond)

alias Realtime.Api

# Where tenant DBs come from — docker containers (default) or external
# servers (USE_EXTERNAL_TENANT_DB=true). The backend is resolved exactly
# once per run, here; everything else dispatches through
# TestTenantDb.Backend.current().
backend = TestTenantDb.Backend.resolve!()
max_cases = backend.max_cases()

repo_config = Application.fetch_env!(:realtime, Realtime.Repo)

# Probe the databases the tenant tests actually exercise. Metadata Postgres can
# have a different version and permission policy from an external tenant cluster.
probe_configs =
  if backend.capability_probe_port() do
    Enum.map(TestTenantDb.Backend.External.ports!(), fn port ->
      [hostname: "127.0.0.1", port: port, username: "supabase_admin", password: "postgres", database: "postgres"]
    end)
  else
    [Keyword.take(repo_config, [:hostname, :port, :username, :password]) ++ [database: "postgres"]]
  end

capabilities =
  Enum.map(probe_configs, fn config ->
    {:ok, conn} = Postgrex.start_link(config)

    try do
      %{rows: [[version, grants, oriole]]} =
        Postgrex.query!(
          conn,
          """
          SELECT current_setting('server_version_num')::int,
            COALESCE(current_setting('supautils.policy_grants', true) LIKE '%realtime.messages%'
              AND current_setting('supautils.policy_grants', true) LIKE '%realtime.subscription%', false),
            EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'orioledb')
          """,
          []
        )

      {version, grants, oriole}
    after
      GenServer.stop(conn)
    end
  end)

{pg_version_num, has_supautils_realtime_grants, orioledb?} =
  case Enum.uniq(capabilities) do
    [capability] -> capability
    _ -> raise "Tenant databases must have matching Postgres versions, supautils policies and extensions"
  end

# `realtime.broadcast_changes(..., NEW record, OLD record, ...)` (introduced in commit 2922658c) called from a trigger via `PERFORM` fails on PG <= 14.5
requires_pg_140006 = if pg_version_num < 140_006, do: :requires_pg_140006

requires_pg_150000 = if pg_version_num < 150_000, do: :requires_pg_150000

# Restriction assertions on the postgres role only when supautils.policy_grants includes realtime.messages and realtime.subscription (supabase/postgres >= 15.14.1.018)
requires_supautils_policy_grants = if !has_supautils_realtime_grants, do: :requires_supautils_policy_grants
requires_no_supautils_policy_grants = if has_supautils_realtime_grants, do: :requires_no_supautils_policy_grants

skip_orioledb = if orioledb?, do: :skip_orioledb
# Older Docker images cannot reliably clean up a shadow database; external tests
# allocate theirs on the separately configured metadata Postgres server.
requires_pgdelta_shadow =
  if backend == TestTenantDb.Backend.Docker and !has_supautils_realtime_grants, do: :requires_pgdelta_shadow

# Tests that kill and recreate a pooled tenant database; only the docker backend
# owns its databases, external servers are supplied to us.
requires_docker_backend = if backend != TestTenantDb.Backend.Docker, do: :requires_docker_backend

exclude =
  Enum.reject(
    [
      :failing,
      requires_pg_140006,
      requires_pg_150000,
      requires_supautils_policy_grants,
      requires_no_supautils_policy_grants,
      skip_orioledb,
      requires_docker_backend,
      requires_pgdelta_shadow
    ],
    &is_nil/1
  )

ExUnit.start(
  exclude: exclude,
  max_cases: max_cases,
  capture_log: Realtime.Env.get_boolean("CAPTURE_LOG", true)
)

max_cases = ExUnit.configuration()[:max_cases]

backend.prepare!()

{:ok, _pid} = TestTenantDb.start_link(max_cases)

# after_suite callbacks run in reverse registration order, so teardown is registered
# first to make it run last — `report_unhealthy_checkouts/1` must be run when the pool
# still exists.
ExUnit.after_suite(&TestTenantDb.shutdown/1)

# A wedged tenant database is recovered from silently (the worker is replaced), so
# the rate has to be reported explicitly or it disappears from CI entirely.
ExUnit.after_suite(&TestTenantDb.report_unhealthy_checkouts/1)

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

:net_kernel.start([TestEnv.node_name()])
region = Realtime.Nodes.region()
[{pid, _}] = :syn.members(RegionNodes, region)
:syn.update_member(RegionNodes, region, pid, fn _ -> [node: node()] end)

end_time = :os.system_time(:millisecond)
IO.puts("[test_helper.exs] Time to start tests: #{end_time - start_time} ms")
