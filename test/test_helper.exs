start_time = :os.system_time(:millisecond)

alias Realtime.Api
alias Realtime.Database
ExUnit.start(exclude: [:failing], max_cases: 4, capture_log: true)

max_cases = ExUnit.configuration()[:max_cases]

Containers.pull()

if System.get_env("REUSE_CONTAINERS") != "true" do
  Containers.stop_containers()
  Containers.stop_container("dev_tenant")
end

{:ok, _pid} = Containers.start_link(max_cases)

for tenant <- Api.list_tenants(), do: Api.delete_tenant_by_external_id(tenant.external_id)

tenant_name = "dev_tenant"
tenant = Containers.initialize(tenant_name)
publication = "supabase_realtime_test"

# Start dev_realtime container to be used in integration tests
{:ok, conn} = Database.connect(tenant, "realtime_seed", :stop)

Database.transaction(conn, fn db_conn ->
  queries = [
    "DROP TABLE IF EXISTS public.test",
    "DROP PUBLICATION IF EXISTS #{publication}",
    "create sequence if not exists test_id_seq;",
    """
    create table "public"."test" (
    "id" int4 not null default nextval('test_id_seq'::regclass),
    "details" text,
    primary key ("id"));
    """,
    "grant all on table public.test to anon;",
    "grant all on table public.test to postgres;",
    "grant all on table public.test to authenticated;",
    "create publication #{publication} for all tables"
  ]

  Enum.each(queries, &Postgrex.query!(db_conn, &1, []))
end)

Ecto.Adapters.SQL.Sandbox.mode(Realtime.Repo, :manual)

Mimic.copy(:syn)
Mimic.copy(Extensions.PostgresCdcRls)
Mimic.copy(Extensions.PostgresCdcRls.Replications)
Mimic.copy(Extensions.PostgresCdcRls.Subscriptions)
Mimic.copy(Realtime.Database)
Mimic.copy(Realtime.GenCounter)
Mimic.copy(Realtime.GenRpc)
Mimic.copy(Realtime.Nodes)
Mimic.copy(Realtime.Repo.Replica)
Mimic.copy(Realtime.RateCounter)
Mimic.copy(Realtime.Tenants.Authorization)
Mimic.copy(Realtime.Tenants.Cache)
Mimic.copy(Realtime.Tenants.Connect)
Mimic.copy(Realtime.Tenants.Migrations)
Mimic.copy(Realtime.Tenants.Rebalancer)
Mimic.copy(Realtime.Tenants.ReplicationConnection)
Mimic.copy(RealtimeWeb.ChannelsAuthorization)
Mimic.copy(RealtimeWeb.Endpoint)
Mimic.copy(RealtimeWeb.JwtVerification)
Mimic.copy(RealtimeWeb.TenantBroadcaster)

# Set the node as the name we use on Clustered.start
# Also update syn metadata to reflect the new name
:net_kernel.start([:"main@127.0.0.1"])
region = Application.get_env(:realtime, :region)
[{pid, _}] = :syn.members(RegionNodes, region)
:syn.update_member(RegionNodes, region, pid, fn _ -> [node: node()] end)

end_time = :os.system_time(:millisecond)
IO.puts("[test_helper.exs] Time to start tests: #{end_time - start_time} ms")
