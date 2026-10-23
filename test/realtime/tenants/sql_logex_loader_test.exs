defmodule Realtime.Tenants.SqlLogexLoaderTest do
  # Direct tests for the loader that reads a tenant's realtime.messages RLS state into the shape
  # SqlLogex.Snapshot.new/1 expects. sql_logex_differential_test.exs exercises this same code
  # against thousands of decisions; this covers the loader itself in isolation.
  use RealtimeWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias Realtime.Database
  alias Realtime.Tenants.SqlLogexLoader
  alias SqlLogex.IR

  setup [:checkout_tenant_and_connect]

  # What load/2 logged with the code, for this tenant only: capture_log sees every process's logs and
  # this file is async, so another test's load can log the same code at the same time.
  defp capture_loader_log(db_conn, tenant) do
    log = capture_log(fn -> assert {:ok, _snapshot} = SqlLogexLoader.load(db_conn, tenant.external_id) end)

    log
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ "SqlLogexUnsupportedPolicies" and &1 =~ ~s(tenant_id: "#{tenant.external_id}")))
    |> Enum.join("\n")
  end

  describe "load/2" do
    test "builds a snapshot with the table's RLS flags, policies and recognised functions", %{
      db_conn: db_conn,
      tenant: tenant
    } do
      Enum.each(SqlLogexPolicies.user_channel_policies(:plain), &Postgrex.query!(db_conn, &1, []))

      assert {:ok, snapshot} = SqlLogexLoader.load(db_conn, tenant.external_id)

      assert %SqlLogex.Snapshot{rls_enabled: true, rls_forced: false} = snapshot
      assert %{"authenticated" => %{bypass_rls: false}} = snapshot.roles

      assert snapshot.policies |> Enum.map(& &1.name) |> Enum.sort() == [
               "lobby",
               "users receive on own channel",
               "users send on own channel"
             ]

      # The supabase/postgres image's auth.uid()/realtime.topic() are known bodies (SqlLogex.Catalog),
      # so the own-channel policy, which only uses them, should be fully modelled.
      own_channel = Enum.find(snapshot.policies, &(&1.name == "users receive on own channel"))
      {ir, :bool} = own_channel.using
      assert IR.supported?(ir)
    end

    test "falls back for a function whose definition isn't a known one", %{db_conn: db_conn, tenant: tenant} do
      # Rolled back: tenant databases are reused across tests, and later ones need the image's auth.role()
      {:error, result} =
        Postgrex.transaction(db_conn, fn conn ->
          Postgrex.query!(conn, SqlLogexPolicies.auth_jwt_statement(), [])

          Postgrex.query!(
            conn,
            "CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql AS $$ select null $$",
            []
          )

          Enum.each(SqlLogexPolicies.user_channel_policies(), &Postgrex.query!(conn, &1, []))

          Postgrex.query!(
            conn,
            "CREATE POLICY \"by role\" ON realtime.messages FOR SELECT USING (auth.role() = 'x')",
            []
          )

          Postgrex.rollback(conn, SqlLogexLoader.load(conn, tenant.external_id))
        end)

      assert {:ok, snapshot} = result

      by_role = Enum.find(snapshot.policies, &(&1.name == "by role"))
      {{:unsupported, {:function, "auth.role", :unknown_definition}}, :unknown} = by_role.using
    end

    test "logs what the policies can't model once, without policy names or SQL", %{db_conn: db_conn, tenant: tenant} do
      Postgrex.query!(db_conn, "CREATE TABLE public.distinct_table_name (distinct_column_name text)", [])

      Postgrex.query!(
        db_conn,
        "CREATE FUNCTION public.distinct_function_name() RETURNS text LANGUAGE sql AS $$ select 'x' $$",
        []
      )

      Postgrex.query!(
        db_conn,
        """
        CREATE POLICY "distinct policy name one" ON realtime.messages FOR SELECT TO authenticated
        USING (EXISTS (select 1 from public.distinct_table_name where distinct_column_name = 'distinct literal'))
        """,
        []
      )

      Postgrex.query!(
        db_conn,
        """
        CREATE POLICY "distinct policy name two" ON realtime.messages FOR INSERT TO authenticated
        WITH CHECK (public.distinct_function_name() = 'distinct literal')
        """,
        []
      )

      log = capture_loader_log(db_conn, tenant)

      assert log =~ "SqlLogexUnsupportedPolicies"
      # No tenant logger metadata, as that may route it to the tenant's own logs
      refute log =~ "project="
      refute log =~ "external_id="
      refute log =~ "tenant_id="
      assert log =~ "unparsed: :exists"
      assert log =~ "{:function, :other_schema, :not_allowlisted}"
      assert log =~ "cmd: \"r\""
      assert log =~ "cmd: \"a\""
      assert log =~ "permissive: true"
      refute log =~ "distinct"
    end

    test "logs nothing about unsupported policies when every policy is modelled", %{db_conn: db_conn, tenant: tenant} do
      Enum.each(SqlLogexPolicies.user_channel_policies(:plain), &Postgrex.query!(db_conn, &1, []))

      assert capture_loader_log(db_conn, tenant) == ""
    end

    test "returns an error, not a crash, when realtime.messages hasn't been migrated" do
      tenant = TestTenantDb.checkout_tenant()
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)

      on_exit(fn ->
        if Process.alive?(db_conn) do
          try do
            GenServer.stop(db_conn, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      assert {:error, _reason} = SqlLogexLoader.load(db_conn, tenant.external_id)
    end
  end
end
