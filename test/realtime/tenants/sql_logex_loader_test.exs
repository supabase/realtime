defmodule Realtime.Tenants.SqlLogexLoaderTest do
  # Direct tests for the loader that reads a tenant's realtime.messages RLS state into the shape
  # SqlLogex.Snapshot.new/1 expects. sql_logex_differential_test.exs exercises this same code
  # against thousands of decisions; this covers the loader itself in isolation.
  use RealtimeWeb.ConnCase, async: true

  alias Realtime.Database
  alias Realtime.Tenants.SqlLogexLoader
  alias SqlLogex.IR

  setup [:checkout_tenant_and_connect]

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
      Postgrex.query!(db_conn, SqlLogexPolicies.auth_jwt_statement(), [])

      Postgrex.query!(
        db_conn,
        "CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql AS $$ select null $$",
        []
      )

      Enum.each(SqlLogexPolicies.user_channel_policies(), &Postgrex.query!(db_conn, &1, []))

      Postgrex.query!(
        db_conn,
        "CREATE POLICY \"by role\" ON realtime.messages FOR SELECT USING (auth.role() = 'x')",
        []
      )

      assert {:ok, snapshot} = SqlLogexLoader.load(db_conn, tenant.external_id)

      by_role = Enum.find(snapshot.policies, &(&1.name == "by role"))
      {{:unsupported, {:function, "auth.role", :unknown_definition}}, :unknown} = by_role.using
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
