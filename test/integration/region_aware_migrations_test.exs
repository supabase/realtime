defmodule Realtime.Integration.RegionAwareMigrationsTest do
  use Realtime.DataCase, async: false
  use Mimic

  alias Containers
  alias Realtime.Tenants
  alias Realtime.Tenants.Migrations

  setup do
    {:ok, port} = Containers.checkout()

    settings = [
      %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "db_host" => "127.0.0.1",
          "db_name" => "postgres",
          "db_user" => "supabase_admin",
          "db_password" => "postgres",
          "db_port" => "#{port}",
          "poll_interval" => 100,
          "poll_max_changes" => 100,
          "poll_max_record_bytes" => 1_048_576,
          "region" => "ap-southeast-2",
          "publication" => "supabase_realtime_test",
          "ssl_enforced" => false
        }
      }
    ]

    tenant = tenant_fixture(%{extensions: settings})
    region = Application.get_env(:realtime, :region)

    {:ok, node} =
      Clustered.start(nil,
        extra_config: [
          {:realtime, :region, Tenants.region(tenant)},
          {:realtime, :master_region, region}
        ]
      )

    Process.sleep(100)

    %{tenant: tenant, node: node}
  end

  test "run_migrations routes to node in tenant's region with expected arguments", %{tenant: tenant, node: node} do
    assert tenant.migrations_ran == 0

    Realtime.GenRpc
    |> Mimic.expect(:call, fn called_node, mod, func, args, opts ->
      assert called_node == node
      assert mod == Migrations
      assert func == :start_migration
      assert opts[:tenant_id] == tenant.external_id

      arg = hd(args)
      assert arg.tenant_external_id == tenant.external_id
      assert arg.migrations_ran == tenant.migrations_ran
      assert arg.settings == hd(tenant.extensions).settings

      call_original(Realtime.GenRpc, :call, [node, mod, func, args, opts])
    end)

    assert :ok = Migrations.run_migrations(tenant)
    Process.sleep(1000)
    tenant = Realtime.Repo.reload!(tenant)
    refute tenant.migrations_ran == 0
  end
end
