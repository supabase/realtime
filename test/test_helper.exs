alias Realtime.Api
alias Realtime.Database
ExUnit.start(exclude: [:failing], max_cases: 4, capture_log: true)
Containers.stop_containers()

for tenant <- Api.list_tenants(), do: Api.delete_tenant(tenant)

# Maybe move this into a module
{:ok, _pid} = Agent.start_link(fn -> Enum.shuffle(5500..9000) end, name: :available_db_ports)

tenant_name = "dev_tenant"
publication = "supabase_realtime_test"
port = Generators.port()
opts = %{external_id: tenant_name, name: tenant_name, port: port, jwt_secret: "secure_jwt_secret"}
tenant = Generators.tenant_fixture(opts)

# Start dev_realtime container to be used in integration tests
Containers.initialize(tenant, true, true)
{:ok, conn} = Database.connect(tenant, "realtime_seed", :stop)

Database.transaction(conn, fn db_conn ->
  queries = [
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

{:ok, _pid} =
  :poolboy.start_link([name: {:local, Containers}, size: 4, max_overflow: 0, worker_module: Containers.Container], [])

# FIXME not needed soon
tenants = for _ <- 0..2, do: Generators.tenant_fixture()
if :ets.whereis(:containers) == :undefined, do: :ets.new(:containers, [:named_table, :set, :public])

# Start other containers to be used based on max test cases
Task.await_many(
  for tenant <- tenants do
    Task.async(fn -> Containers.initialize(tenant) end)
  end,
  :infinity
)

Ecto.Adapters.SQL.Sandbox.mode(Realtime.Repo, :manual)
