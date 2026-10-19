defmodule Realtime.TenantsTest do
  use Realtime.DataCase, async: true

  alias Realtime.Database
  alias Realtime.Env
  alias Realtime.GenCounter
  alias Realtime.Tenants
  doctest Realtime.Tenants

  describe "tenants" do
    test "get_tenant_limits/1" do
      tenant = tenant_fixture()
      keys = Tenants.limiter_keys(tenant)

      for key <- keys do
        GenCounter.add(key, 9)
      end

      limits = Tenants.get_tenant_limits(tenant, keys)

      [all] = Enum.filter(limits, fn e -> e.limiter == Tenants.requests_per_second_key(tenant) end)
      assert all.counter == 9

      [user_channels] = Enum.filter(limits, fn e -> e.limiter == Tenants.channels_per_client_key(tenant) end)
      assert user_channels.counter == 9

      [channel_joins] = Enum.filter(limits, fn e -> e.limiter == Tenants.joins_per_second_key(tenant) end)
      assert channel_joins.counter == 9

      [tenant_events] = Enum.filter(limits, fn e -> e.limiter == Tenants.events_per_second_key(tenant) end)
      assert tenant_events.counter == 9
    end
  end

  describe "region/1" do
    test "returns the region of the tenant" do
      attrs = %{
        "external_id" => random_string(),
        "name" => "tenant",
        "extensions" => [
          %{
            "type" => "postgres_cdc_rls",
            "settings" => %{
              "db_host" => "127.0.0.1",
              "db_name" => "postgres",
              "db_user" => "supabase_admin",
              "db_password" => "postgres",
              "db_port" => "#{Env.unused_port()}",
              "poll_interval" => 100,
              "poll_max_changes" => 100,
              "poll_max_record_bytes" => 1_048_576,
              "region" => "us-east-1",
              "publication" => "supabase_realtime_test",
              "ssl_enforced" => false
            }
          }
        ],
        "postgres_cdc_default" => "postgres_cdc_rls",
        "jwt_secret" => "new secret",
        "jwt_jwks" => nil
      }

      {:ok, tenant} = Realtime.Api.create_tenant(attrs)
      assert Tenants.region(tenant) == "us-east-1"
    end

    test "returns nil if no extension is set" do
      attrs = %{
        "external_id" => random_string(),
        "name" => "tenant",
        "extensions" => [],
        "postgres_cdc_default" => "postgres_cdc_rls",
        "jwt_secret" => "new secret",
        "jwt_jwks" => nil
      }

      {:ok, tenant} = Realtime.Api.create_tenant(attrs)
      assert Tenants.region(tenant) == nil
    end
  end

  describe "create_messages_partitions/1" do
    test "returns a partition creation error and can be retried after the lock is released" do
      tenant = TestTenantDb.checkout_tenant(run_migrations: true)
      {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)
      {:ok, locking_conn} = Database.connect(tenant, "realtime_test", :stop)

      %{rows: partitions} =
        Postgrex.query!(
          conn,
          "SELECT format('DROP TABLE %s', inhrelid::regclass) FROM pg_inherits WHERE inhparent = 'realtime.messages'::regclass",
          []
        )

      Enum.each(partitions, fn [drop_partition] -> Postgrex.query!(conn, drop_partition, []) end)

      Postgrex.query!(conn, "SET lock_timeout = '100ms'", [])
      Postgrex.query!(locking_conn, "BEGIN", [])
      Postgrex.query!(locking_conn, "LOCK TABLE realtime.messages IN ACCESS EXCLUSIVE MODE", [])

      result =
        try do
          Tenants.create_messages_partitions(conn)
        after
          Postgrex.query!(locking_conn, "ROLLBACK", [])
        end

      assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} = result

      assert {:ok, %{rows: [[0]]}} =
               Postgrex.query(
                 conn,
                 "SELECT count(*) FROM pg_inherits WHERE inhparent = 'realtime.messages'::regclass",
                 []
               )

      assert :ok = Tenants.create_messages_partitions(conn)

      assert {:ok, %{rows: [[5]]}} =
               Postgrex.query(
                 conn,
                 "SELECT count(*) FROM pg_inherits WHERE inhparent = 'realtime.messages'::regclass",
                 []
               )
    end

    test "running twice keeps the same partitions" do
      tenant = TestTenantDb.checkout_tenant(run_migrations: true)
      {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)

      assert :ok = Tenants.create_messages_partitions(conn)
      assert :ok = Tenants.create_messages_partitions(conn)

      assert {:ok, %{rows: [[5]]}} =
               Postgrex.query(
                 conn,
                 "SELECT count(*) FROM pg_inherits WHERE inhparent = 'realtime.messages'::regclass",
                 []
               )
    end
  end
end
