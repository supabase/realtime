import Ecto.Adapters.SQL, only: [query!: 3]

alias Realtime.Api.Tenant
alias Realtime.Database
alias Realtime.Repo
alias Realtime.Tenants

tenant_name = "realtime-dev"
default_db_host = "127.0.0.1"

{:ok, tenant} =
  Repo.transaction(fn ->
    case Repo.get_by(Tenant, external_id: tenant_name) do
      %Tenant{} = tenant -> Repo.delete!(tenant)
      nil -> {:ok, nil}
    end

    tenant =
      %Tenant{}
      |> Tenant.changeset(%{
        "name" => tenant_name,
        "external_id" => tenant_name,
        "jwt_secret" => System.get_env("API_JWT_SECRET", "super-secret-jwt-token-with-at-least-32-characters-long"),
        "jwt_jwks" => System.get_env("API_JWT_JWKS") |> then(fn v -> if v, do: Jason.decode!(v) end),
        "extensions" => [
          %{
            "type" => "postgres_cdc_rls",
            "settings" => %{
              "db_name" => System.get_env("DB_NAME", "postgres"),
              "db_host" => System.get_env("DB_HOST", default_db_host),
              "db_user" => System.get_env("DB_USER", "supabase_admin"),
              "db_password" => System.get_env("DB_PASSWORD", "postgres"),
              "db_port" => System.get_env("DB_PORT", "5433"),
              "region" => "us-east-1",
              "poll_interval_ms" => 100,
              "poll_max_record_bytes" => 1_048_576,
              "ssl_enforced" => false
            }
          }
        ]
      })
      |> Repo.insert!()

    publication = "supabase_realtime"

    [
      "drop publication if exists #{publication}",
      "drop table if exists public.test_tenant;",
      "create table public.test_tenant ( id SERIAL PRIMARY KEY, details text );",
      "grant all on table public.test_tenant to anon;",
      "grant all on table public.test_tenant to postgres;",
      "grant all on table public.test_tenant to authenticated;",
      "create publication #{publication} for table public.test_tenant"
    ]
    |> Enum.each(&query!(Repo, &1, []))

    tenant
  end)

# Reset Tenant DB
settings = Database.from_tenant(tenant, "realtime_migrations", :stop)
settings = %{settings | max_restarts: 0, ssl: false}
{:ok, tenant_conn} = Database.connect_db(settings)

Postgrex.transaction(tenant_conn, fn db_conn ->
  Postgrex.query!(db_conn, "DROP SCHEMA IF EXISTS realtime CASCADE", [])
  Postgrex.query!(db_conn, "CREATE SCHEMA IF NOT EXISTS realtime", [])
end)

case Tenants.Migrations.run_migrations(tenant) do
  :ok -> :ok
  :noop -> :ok
  _ -> raise "Running Migrations failed"
end

Tenants.Migrations.run_migrations(tenant)
