# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias Realtime.Api.Tenant
alias Realtime.Repo

Application.put_env(:realtime, :db_enc_key, "1234567890123456")

tenant_name = "dev_tenant"

Tenant
|> Repo.get_by(external_id: tenant_name)
|> Repo.preload(:extensions)
|> case do
  nil -> %Tenant{}
  tenant -> tenant
end
|> Tenant.changeset(%{
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
})
|> Repo.insert!(conflict_target: [:external_id], on_conflict: :replace_all)

[
  "drop publication realtime_test",
  "create publication realtime_test for all tables"
] |> Enum.each(&Repo.query(Repo, &1, []))
