alias Realtime.Api
import Ecto.Adapters.SQL, only: [query: 3]

db_conf = Application.get_env(:realtime, Realtime.Repo)

tenant_name = "dev_tenant"
create_param = %{
  "name" => tenant_name,
  "extensions" => [
    %{
      "type" => "postgres",
      "settings" => %{
        "db_host" => db_conf[:hostname],
        "db_name" => db_conf[:database],
        "db_user" => db_conf[:username],
        "db_password" => db_conf[:password],
        "db_port" => "5432",
        "poll_interval_ms" => 100,
        "poll_max_changes" => 100,
        "poll_max_record_bytes" => 1_048_576,
        "region" => "us-east-1"
      }
    }
  ],
  "external_id" => tenant_name,
  "jwt_secret" => "d3v_HtNXEpT+zfsyy1LE1WPGmNKLWRfw/rpjnVtCEEM2cSFV2s+kUh5OKX7TPYmG"
}

if !Api.get_tenant_by_external_id(tenant_name) do
  Api.create_tenant(create_param)
end

[
  "create publication realtime_test for all tables"
] |> Enum.each(&query(Realtime.Repo, &1, []))
