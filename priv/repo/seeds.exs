alias Realtime.{Api.Tenant, Repo}
import Ecto.Adapters.SQL, only: [query: 3]

tenant_name = "realtime-dev-tenant"

Repo.transaction(fn ->
  case Repo.get_by(Tenant, external_id: tenant_name) do
    %Tenant{} = tenant -> Repo.delete!(tenant)
    nil -> {:ok, nil}
  end

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
      "drop publication if exists #{publication}",
      "drop table if exists public.test_tenant;",
      "create table public.test_tenant (
        id SERIAL PRIMARY KEY,
        details text
        );",
      "grant all on table public.test_tenant to anon;",
      "grant all on table public.test_tenant to postgres;",
      "grant all on table public.test_tenant to authenticated;",
      "create publication #{publication} for table public.test_tenant"
    ]
    |> Enum.each(&query(Repo, &1, []))
  end)
