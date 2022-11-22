alias Realtime.Api
alias Realtime.Repo
import Ecto.Adapters.SQL, only: [query: 3]

publication = "supabase_realtime_test"

db_conf = Application.get_env(:realtime, Repo)

tenant_name = "dev_tenant"

if Api.get_tenant_by_external_id(tenant_name) do
  Api.delete_tenant_by_external_id(tenant_name)
end

%{
  "name" => tenant_name,
  "extensions" => [
    %{
      "type" => "postgres_cdc_rls",
      "settings" => %{
        "db_host" => db_conf[:hostname],
        "db_name" => db_conf[:database],
        "db_user" => db_conf[:username],
        "db_password" => db_conf[:password],
        "db_port" => "5432",
        "poll_interval_ms" => 100,
        "poll_max_changes" => 100,
        "poll_max_record_bytes" => 1_048_576,
        "publication" => publication,
        "region" => "us-east-1"
      }
    }
  ],
  "external_id" => tenant_name,
  "jwt_secret" => "secure_jwt_secret"
} |> Api.create_tenant()

query(Repo, "drop publication #{publication}", [])

{:ok, _} = Repo.transaction(fn ->
  [
    "drop table if exists \"public\".\"test\";",
    "create sequence if not exists test_id_seq;",
    "create table \"public\".\"test\" (
        \"id\" int4 not null default nextval('test_id_seq'::regclass),
        \"details\" text,
        primary key (\"id\")
    );",
    "grant all on table public.test to anon;",
    "grant all on table public.test to postgres;",
    "grant all on table public.test to authenticated;",
    "create publication #{publication} for all tables"
  ] |> Enum.each(&query(Repo, &1, []))
end)
