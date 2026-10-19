defmodule Realtime.TenantsTest do
  use Realtime.DataCase, async: true

  alias Realtime.Database
  alias Realtime.Env
  alias Realtime.GenCounter
  alias Realtime.Tenants

  import ExUnit.CaptureLog
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

    test "does not lock partitions that already exist" do
      tenant = TestTenantDb.checkout_tenant(run_migrations: true)
      {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)
      {:ok, holder} = Database.connect(tenant, "realtime_test", :stop)

      assert :ok = Tenants.create_messages_partitions(conn)

      Postgrex.transaction(holder, fn holder_conn ->
        # Conflicts with the ACCESS EXCLUSIVE lock taken by ALTER TABLE ... OWNER TO
        Postgrex.query!(holder_conn, "LOCK TABLE realtime.#{today_partition()} IN ACCESS SHARE MODE", [])

        task = Task.async(fn -> Tenants.create_messages_partitions(conn) end)
        assert {:ok, :ok} = Task.yield(task, 2_000)
      end)
    end

    test "creates missing partitions owned by supabase_realtime_admin and leaves existing ones untouched" do
      tenant = TestTenantDb.checkout_tenant(run_migrations: true)
      {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)

      today = Date.utc_today()
      yesterday = partition_name(Date.add(today, -1))
      tomorrow = partition_name(Date.add(today, 1))

      Postgrex.query!(conn, "DROP TABLE realtime.#{yesterday}", [])
      Postgrex.query!(conn, "DROP TABLE realtime.#{tomorrow}", [])
      Postgrex.query!(conn, "ALTER TABLE realtime.#{today_partition()} OWNER TO postgres", [])

      assert :ok = Tenants.create_messages_partitions(conn)

      expected = Map.new(-1..3, fn offset -> {partition_name(Date.add(today, offset)), Date.add(today, offset)} end)
      partitions = partitions(conn)

      assert Map.keys(partitions) |> Enum.sort() == Map.keys(expected) |> Enum.sort()

      for {name, date} <- expected do
        {owner, bound} = partitions[name]
        assert bound =~ "FROM ('#{date} 00:00:00') TO ('#{Date.add(date, 1)} 00:00:00')"
        assert owner == if(name == today_partition(), do: "postgres", else: "supabase_realtime_admin")
      end
    end

    test "logs and continues when a partition can't be created" do
      tenant = TestTenantDb.checkout_tenant(run_migrations: true)
      {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)

      today = Date.utc_today()
      tomorrow = partition_name(Date.add(today, 1))
      day_after = partition_name(Date.add(today, 2))

      Postgrex.query!(conn, "DROP TABLE realtime.#{tomorrow}", [])
      Postgrex.query!(conn, "DROP TABLE realtime.#{day_after}", [])

      # Covers tomorrow's range under a different name, so creating tomorrow's partition fails
      Postgrex.query!(
        conn,
        "CREATE TABLE realtime.messages_custom PARTITION OF realtime.messages FOR VALUES FROM ('#{Date.add(today, 1)}') TO ('#{Date.add(today, 2)}')",
        []
      )

      log = capture_log(fn -> assert :ok = Tenants.create_messages_partitions(conn) end)

      assert log =~ "PartitionCreationFailed"
      partitions = partitions(conn)
      refute Map.has_key?(partitions, tomorrow)
      assert Map.has_key?(partitions, day_after)
    end

    test "logs and returns :ok when existing partitions can't be listed" do
      tenant = TestTenantDb.checkout_tenant(run_migrations: true)
      {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)

      Postgrex.query!(conn, "DROP TABLE realtime.messages CASCADE", [])

      log = capture_log(fn -> assert :ok = Tenants.create_messages_partitions(conn) end)

      assert log =~ "PartitionCreationFailed"
    end
  end

  defp today_partition, do: partition_name(Date.utc_today())

  defp partition_name(date), do: "messages_#{date |> Date.to_iso8601() |> String.replace("-", "_")}"

  defp partitions(conn) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT c.relname, pg_get_userbyid(c.relowner), pg_get_expr(c.relpartbound, c.oid)
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'realtime.messages'::regclass
        """,
        []
      )

    Map.new(rows, fn [name, owner, bound] -> {name, {owner, bound}} end)
  end
end
