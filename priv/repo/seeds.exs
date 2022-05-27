# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias Realtime.Api
import Ecto.Adapters.SQL, only: [query: 3]

Application.put_env(:realtime, :db_enc_key, "1234567890123456")

tenant_name = "dev_tenant"
create_param = %{
  "name" => tenant_name,
  "extensions" => [
    %{
      "type" => "postgres",
      "settings" => %{
        "db_host" => "127.0.0.1",
        "db_name" => "postgres",
        "db_user" => "postgres",
        "db_password" => "postgres",
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
