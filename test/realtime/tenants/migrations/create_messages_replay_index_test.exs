defmodule Realtime.Tenants.Migrations.CreateMessagesReplayIndexTest do
  use Realtime.DataCase, async: false

  alias Realtime.Tenants.Migrations
  alias Realtime.Database

  setup do
    tenant = Containers.checkout_tenant(run_migrations: false)
    :ok = run_migrations(tenant)
    {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)

    date_start = Date.utc_today() |> Date.add(-5)
    date_end = Date.utc_today() |> Date.add(1)
    create_messages_partitions(conn, date_start, date_end)

    message_fixture(tenant)
    %{conn: conn, tenant: tenant}
  end

  describe "change/0" do
    test "recreate partitions with new index", %{conn: conn, tenant: tenant} do
      assert length(list_partitions(conn)) == 9

      assert :ok = Migrations.run_migrations(tenant)

      new_partitions = list_partitions(conn)
      new_indices = list_indices(conn)

      assert length(new_partitions) == 5
      assert map_size(new_indices) == 5

      Enum.each(new_partitions, fn new_partition ->
        assert new_indices[new_partition]
      end)
    end
  end

  # Run migrations for a given tenant before the CreateMessagesReplayIndex migration
  defp run_migrations(tenant) do
    %{extensions: [%{settings: settings} | _]} = tenant
    settings = Database.from_settings(settings, "realtime_migrations", :stop)

    [
      hostname: settings.hostname,
      port: settings.port,
      database: settings.database,
      password: settings.password,
      username: settings.username,
      pool_size: settings.pool_size,
      backoff_type: settings.backoff_type,
      socket_options: settings.socket_options,
      parameters: [application_name: settings.application_name],
      ssl: settings.ssl
    ]
    |> Realtime.Repo.with_dynamic_repo(fn repo ->
      try do
        opts = [to_exclusive: 20_250_905_041_441, prefix: "realtime", dynamic_repo: repo, log: false]
        migrations = Realtime.Tenants.Migrations.migrations()
        Ecto.Migrator.run(Realtime.Repo, migrations, :up, opts)

        :ok
      rescue
        error ->
          {:error, error}
      end
    end)
  end

  defp list_partitions(conn) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT child.relname
        FROM pg_inherits
        JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
        JOIN pg_class child ON pg_inherits.inhrelid = child.oid
        JOIN pg_namespace nmsp_parent ON nmsp_parent.oid = parent.relnamespace
        JOIN pg_namespace nmsp_child ON nmsp_child.oid = child.relnamespace
        WHERE parent.relname = 'messages'
        AND nmsp_child.nspname = 'realtime'
        """
      )

    List.flatten(rows)
  end

  defp list_indices(conn) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT tablename, indexname
        FROM pg_indexes
        WHERE schemaname = 'realtime' AND indexname LIKE '%_inserted_at_topic_private_idx'
        """
      )

    Map.new(rows, fn [table_name, index_name] ->
      {table_name, index_name}
    end)
  end
end
