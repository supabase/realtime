alias Realtime.{Api.Tenant, Repo}
import Ecto.Adapters.SQL, only: [query: 3]

tenant_name = "localhost"

Repo.transaction(fn ->
  case Repo.get_by(Tenant, external_id: tenant_name) do
    %Tenant{} = tenant -> Repo.delete!(tenant)
    nil -> {:ok, nil}
  end

  # JWT in dev will be
  # eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE5MDg1MDM0MjUsImlhdCI6MTYyNzg4NjQ0MCwicm9sZSI6InNlcnZpY2Vfcm9sZSJ9.9FzvbdQcM1k_to7XtOJcu_WXHaTQ7wlWAGafhf7VK8Y

  # Subscribe to fake tenant table with the Inspector
  # http://localhost:4000/inspector/new?bearer=&channel=any&host=http%3A%2F%2Frealtime-dev-tenant.localhost.localhost%3A4000&log_level=info&schema=%2A&table=%2A&token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE5MDg1MDM0MjUsImlhdCI6MTYyNzg4NjQ0MCwicm9sZSI6InNlcnZpY2Vfcm9sZSJ9.9FzvbdQcM1k_to7XtOJcu_WXHaTQ7wlWAGafhf7VK8Y

  %Tenant{}
  |> Tenant.changeset(%{
    "name" => tenant_name,
    "external_id" => tenant_name,
    "jwt_secret" => "super-secret-jwt-token-with-at-least-32-characters-long",
    "extensions" => [
      %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "db_name" => "postgres",
          "db_host" => "localhost",
          "db_user" => "postgres",
          "db_password" => "postgres",
          "db_port" => "5432",
          "region" => "us-east-1",
          "poll_interval_ms" => 100,
          "poll_max_record_bytes" => 1_048_576,
          "ip_version" => 4
        }
      }
    ]
  })
  |> Repo.insert!()
end)

publication = "supabase_realtime"

{:ok, _} =
  Repo.transaction(fn ->
    [
      # drop first
      "drop   publication if exists #{publication}",
      "drop   table if exists public.test_tenant",
      "revoke usage on schema public from anon, authenticated, service_role;",
      "alter default privileges in schema public revoke all on tables from anon, authenticated, service_role;",
      "alter default privileges in schema public revoke all on functions from anon, authenticated, service_role;",
      "alter default privileges in schema public revoke all on sequences from anon, authenticated, service_role;",
      "drop role if exists anon",
      "drop role if exists authenticated",
      "drop role if exists service_role",

      # roles
      "create role anon          nologin noinherit",
      "create role authenticated nologin noinherit",
      "create role service_role  nologin noinherit bypassrls",

      # schema
      "create schema if not exists realtime",

      # example tenant tables
      "create table public.test_tenant (
        id SERIAL PRIMARY KEY,
        details text
        );",

      # role grants
      "grant all   on table  public.test_tenant to anon",
      "grant all   on table  public.test_tenant to postgres",
      "grant all   on table  public.test_tenant to authenticated",
      "grant usage on schema public             to anon, authenticated, service_role",

      # priviledges
      "alter default privileges in schema public grant all on tables    to anon, authenticated, service_role",
      "alter default privileges in schema public grant all on functions to anon, authenticated, service_role",
      "alter default privileges in schema public grant all on sequences to anon, authenticated, service_role",

      # publication
      "create publication #{publication} for table public.test_tenant"
    ]
    |> Enum.each(&query(Repo, &1, []))
  end)
