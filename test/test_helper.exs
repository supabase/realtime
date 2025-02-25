alias Ecto.Adapters.SQL.Sandbox
alias Realtime.Api
alias Realtime.Database
max_cases = System.get_env("MAX_CASES", "2") |> String.to_integer()
ExUnit.start(exclude: [:failing], max_cases: max_cases)
Containers.stop_containers()

for tenant <- Api.list_tenants() do
  Api.delete_tenant(tenant)
end

tenant_name = "dev_tenant"
publication = "supabase_realtime_test"
port = Enum.random(5500..9000)
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

containers = Application.get_env(:ex_unit, :max_cases, System.schedulers()) * 2
tenants = for _ <- 0..containers, do: Generators.tenant_fixture()

# Start other containers to be used based on max test cases
Task.await_many(
  for tenant <- tenants do
    Task.async(fn -> Containers.initialize(tenant) end)
  end,
  :infinity
)

ExUnit.after_suite(fn _ ->
  Sandbox.checkout(Realtime.Repo)

  Enum.each(tenants, &Realtime.Api.delete_tenant/1)
end)

Ecto.Adapters.SQL.Sandbox.mode(Realtime.Repo, :auto)
