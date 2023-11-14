alias Realtime.{Api.Tenant, Repo}
import Ecto.Adapters.SQL, only: [query: 3]

tenant_name = "realtime-dev"
default_db_host = if Mix.env() in [:dev, :test], do: "localhost", else: "host.docker.internal"

Repo.transaction(fn ->
  case Repo.get_by(Tenant, external_id: tenant_name) do
    %Tenant{} = tenant -> Repo.delete!(tenant)
    nil -> {:ok, nil}
  end

  %Tenant{}
  |> Tenant.changeset(%{
    "name" => tenant_name,
    "external_id" => tenant_name,
    "jwt_secret" =>
      System.get_env("API_JWT_SECRET", "super-secret-jwt-token-with-at-least-32-characters-long"),
    "extensions" => [
      %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "db_name" => System.get_env("DB_NAME", "postgres"),
          "db_host" => System.get_env("DB_HOST", default_db_host),
          "db_user" => System.get_env("DB_USER", "postgres"),
          "db_password" => System.get_env("DB_PASSWORD", "postgres"),
          "db_port" => System.get_env("DB_PORT", "5432"),
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

if Mix.env() in [:dev, :test] do
  publication = "supabase_realtime"

  {:ok, _} =
    Repo.transaction(fn ->
      [
        "drop publication if exists #{publication}",
        "drop table if exists public.test_tenant;",
        "create table public.test_tenant ( id SERIAL PRIMARY KEY, details text );",
        "grant all on table public.test_tenant to anon;",
        "grant all on table public.test_tenant to postgres;",
        "grant all on table public.test_tenant to authenticated;",
        "create publication #{publication} for table public.test_tenant"
      ]
      |> Enum.each(&query(Repo, &1, []))
    end)
end
