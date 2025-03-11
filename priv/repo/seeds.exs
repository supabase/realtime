require Logger
alias Realtime.{Api.Tenant, Repo}
import Ecto.Adapters.SQL, only: [query: 3]

tenant_name = System.get_env("SELF_HOST_TENANT_NAME", "realtime-dev")
env = if :ets.whereis(Mix.State) != :undefined, do: Mix.env(), else: :prod
default_db_host = if env in [:dev, :test], do: "127.0.0.1", else: "host.docker.internal"

Logger.info("Starting seeding process for tenant: #{tenant_name}, environment: #{env}")
Logger.info("Default DB host: #{default_db_host}")

Repo.transaction(fn ->
  {:ok, conn} = Repo.checkout()
  current_schema = Postgrex.query!(conn, "SHOW search_path", []) |> Map.get(:rows) |> List.first() |> List.first()
  Logger.info("Current schema in transaction: #{current_schema}")

  case Repo.get_by(Tenant, external_id: tenant_name) do
    %Tenant{} = tenant ->
      Logger.info("Deleting existing tenant: #{tenant_name}")
      Repo.delete!(tenant)
    nil ->
      Logger.info("No existing tenant found for: #{tenant_name}")
  end

  now = DateTime.utc_now()
  Logger.info("Generated timestamp for insertion: #{inspect(now)}")

  changeset = Tenant.changeset(%Tenant{}, %{
    "name" => tenant_name,
    "external_id" => tenant_name,
    "jwt_secret" => System.get_env("API_JWT_SECRET", "super-secret-jwt-token-with-at-least-32-characters-long"),
    "jwt_jwks" => System.get_env("API_JWT_JWKS") |> then(fn v -> if v, do: Jason.decode!(v) end),
    "extensions" => [
      %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "db_name" => System.get_env("DB_NAME", "postgres"),
          "db_host" => System.get_env("DB_HOST", "your-rds.ap-southeast-2.rds.amazonaws.com"),
          "db_user" => System.get_env("DB_USER", "supabase_admin"),
          "db_password" => System.get_env("DB_PASSWORD", "your-super-secret-and-long-postgres-password"),
          "db_port" => System.get_env("DB_PORT", "5432"),
          "region" => "ap-southeast-2",
          "poll_interval_ms" => 100,
          "poll_max_record_bytes" => 1_048_576,
          "ssl_enforced" => false
        }
      }
    ],
    "inserted_at" => now,
    "updated_at" => now
  })

  Logger.info("Changeset before insert: #{inspect(changeset.changes)}")
  case Repo.insert(changeset) do
    {:ok, tenant} ->
      Logger.info("✅ Successfully inserted tenant: #{tenant.external_id}")
    {:error, changeset} ->
      Logger.error("❌ Failed to insert tenant: #{inspect(changeset.errors)}")
      raise "Seeding failed"
  end
end)

if env in [:dev, :test] do
  publication = "supabase_realtime"
  Logger.info("Setting up test environment with publication: #{publication}")

  {:ok, _} =
    Repo.transaction(fn ->
      [
        "drop publication if exists #{publication}",
        "drop table if exists public.test_tenant;",
        "create table public.test_tenant (id SERIAL PRIMARY KEY, details text);",
        "grant all on table public.test_tenant to anon;",
        "grant all on table public.test_tenant to postgres;",
        "grant all on table public.test_tenant to authenticated;",
        "create publication #{publication} for table public.test_tenant"
      ]
      |> Enum.each(fn sql ->
        Logger.info("Executing SQL: #{sql}")
        case query(Repo, sql, []) do
          {:ok, _} -> Logger.info("✅ SQL executed successfully: #{sql}")
          {:error, error} -> Logger.error("❌ SQL execution failed: #{inspect(error)}")
        end
      end)
    end)
end
