defmodule Realtime.Tenants.CacheTest do
  use Realtime.DataCase

  alias Realtime.Api
  alias Realtime.Tenants

  @db_conf Application.compile_env(:realtime, Realtime.Repo)

  setup do
    params = %{
      external_id: "external_id",
      name: "localhost",
      extensions: [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => @db_conf[:hostname],
            "db_name" => @db_conf[:database],
            "db_user" => @db_conf[:username],
            "db_password" => @db_conf[:password],
            "db_port" => "5432",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1"
          }
        }
      ],
      postgres_cdc_default: "postgres_cdc_rls",
      jwt_secret: "new secret",
      max_concurrent_users: 200,
      max_events_per_second: 100
    }

    {:ok, tenant} = Api.create_tenant(params)

    %{tenant: tenant}
  end

  describe "get_tenant_by_external_id/1" do
    test "tenants cache returns a cached result", %{tenant: tenant} do
      external_id = "external_id"

      assert %Api.Tenant{name: "localhost"} = Tenants.Cache.get_tenant_by_external_id(external_id)

      Api.update_tenant(tenant, %{name: "new name"})

      assert %Api.Tenant{name: "new name"} = Tenants.get_tenant_by_external_id(external_id)

      assert %Api.Tenant{name: "localhost"} = Tenants.Cache.get_tenant_by_external_id(external_id)
    end
  end
end
