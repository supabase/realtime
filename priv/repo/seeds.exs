alias Realtime.{Api.Tenant, Repo}

tenant_name = "realtime-dev"

Repo.transaction(fn ->
  case Repo.get_by(Tenant, external_id: tenant_name) do
    %Tenant{} = tenant -> Repo.delete!(tenant)
    nil -> {:ok, nil}
  end

  %Tenant{}
  |> Tenant.changeset(%{
    "name" => tenant_name,
    "external_id" => tenant_name,
    "jwt_secret" => System.get_env("API_JWT_SECRET", "a1d99c8b-91b6-47b2-8f3c-aa7d9a9ad20f"),
    "extensions" => [
      %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "db_name" => System.get_env("DB_NAME", "postgres"),
          "db_host" => System.get_env("DB_HOST", "host.docker.internal"),
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
