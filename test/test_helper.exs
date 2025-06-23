start_time = :os.system_time(:millisecond)

alias Realtime.Api
alias Realtime.Database
ExUnit.start(exclude: [:failing], max_cases: 3, capture_log: true)

max_cases = ExUnit.configuration()[:max_cases]

Containers.pull()

if System.get_env("REUSE_CONTAINERS") != "true" do
  Containers.stop_containers()
  Containers.stop_container("dev_tenant")
end

{:ok, _pid} = Containers.start_link(max_cases)

for tenant <- Api.list_tenants(), do: Api.delete_tenant(tenant)

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

end_time = :os.system_time(:millisecond)
IO.puts("[test_helper.exs] Time to start tests: #{end_time - start_time} ms")

Mimic.copy(:syn)
Mimic.copy(Realtime.GenCounter)
Mimic.copy(Realtime.Nodes)
Mimic.copy(Realtime.RateCounter)
Mimic.copy(Realtime.Tenants.Authorization)
Mimic.copy(Realtime.Tenants.Connect)
Mimic.copy(Realtime.Tenants.Migrations)
Mimic.copy(Realtime.Tenants.Cache)
Mimic.copy(RealtimeWeb.ChannelsAuthorization)
Mimic.copy(RealtimeWeb.Endpoint)
Mimic.copy(RealtimeWeb.JwtVerification)
Mimic.copy(Realtime.Tenants.ReplicationConnection)
