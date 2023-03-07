defmodule Realtime.TenantsTest do
  use Realtime.DataCase

  import Mock

  alias Realtime.Api
  alias Realtime.GenCounter
  alias Realtime.Tenants

  describe "tenants" do
    db_conf = Application.compile_env(:realtime, Realtime.Repo)

    @valid_attrs %{
      external_id: "external_id",
      name: "localhost",
      extensions: [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => db_conf[:hostname],
            "db_name" => db_conf[:database],
            "db_user" => db_conf[:username],
            "db_password" => db_conf[:password],
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

    def tenant_fixture(attrs \\ %{}) do
      {:ok, tenant} =
        attrs
        |> Enum.into(@valid_attrs)
        |> Api.create_tenant()

      tenant
    end

    test "get_tenant_limits/1" do
      tenant = tenant_fixture()

      with_mocks([
        {GenCounter, [], [get: fn _ -> {:ok, 9} end]}
      ]) do
        keys = Tenants.limiter_keys(tenant)
        limits = Tenants.get_tenant_limits(tenant, keys)

        [all] =
          Enum.filter(limits, fn e -> e.limiter == Tenants.requests_per_second_key(tenant) end)

        assert all.counter == 9

        [user_channels] =
          Enum.filter(limits, fn e -> e.limiter == Tenants.channels_per_client_key(tenant) end)

        assert user_channels.counter == 9

        [channel_joins] =
          Enum.filter(limits, fn e -> e.limiter == Tenants.joins_per_second_key(tenant) end)

        assert channel_joins.counter == 9

        [tenant_events] =
          Enum.filter(limits, fn e -> e.limiter == Tenants.events_per_second_key(tenant) end)

        assert tenant_events.counter == 9
      end
    end
  end
end
