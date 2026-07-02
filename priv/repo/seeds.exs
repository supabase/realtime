require Logger

import Ecto.Adapters.SQL, only: [query: 3]

alias Realtime.Api.Tenant
alias Realtime.Repo
alias Realtime.Tenants

tenant_name = System.get_env("SELF_HOST_TENANT_NAME", "realtime-dev")
default_db_host = "host.docker.internal"

# Tenant per-CDC ssl_enforced flag. Distinct from DB_SSL (which controls
# Realtime's connection to its own metadata DB) — this flips whether
# tenant CDC connections use TLS. Defaults to false to preserve existing
# behavior; set to "true" or "1" when seeding against a managed Postgres
# that requires TLS (e.g. AWS RDS with rds.force_ssl=1, GCP Cloud SQL
# with "require SSL/TLS connections" on).
db_ssl_enforced =
  System.get_env("DB_SSL_ENFORCED", "false")
  |> String.trim()
  |> String.downcase()
  |> then(&(&1 in ["true", "1"]))

{:ok, tenant} =
  Repo.transaction(fn ->
    case Repo.get_by(Tenant, external_id: tenant_name) do
      %Tenant{} = tenant -> Repo.delete!(tenant)
      nil -> {:ok, nil}
    end

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
            "db_user_realtime" =>
              Realtime.Env.get_binary("DB_USER_REALTIME", fn ->
                Realtime.Env.get_binary("DB_USER", "supabase_realtime_admin")
              end),
            "db_pass_realtime" =>
              Realtime.Env.get_binary("DB_PASS_REALTIME", fn -> Realtime.Env.get_binary("DB_PASSWORD", "postgres") end),
            "db_port" => System.get_env("DB_PORT", "5433"),
            "region" => "us-east-1",
            "poll_interval_ms" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "ssl_enforced" => db_ssl_enforced
          }
        }
      ]
    })
    |> Repo.insert!()
  end)

tenant = Tenants.get_tenant_by_external_id(tenant_name)

with res when res in [:noop, :ok] <- Tenants.Migrations.run_migrations(tenant),
     :ok <- Tenants.Janitor.MaintenanceTask.run(tenant.external_id) do
  Logger.info("Tenant set-up successfully")
else
  error ->
    Logger.info("Failed to set-up tenant: #{inspect(error)}")
end
