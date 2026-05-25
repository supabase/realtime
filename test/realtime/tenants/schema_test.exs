defmodule Realtime.Tenants.SchemaTest do
  @moduledoc false

  use Realtime.DataCase, async: false
  alias Realtime.Database

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    {:ok, settings} = Database.from_tenant(tenant, "realtime_test", :stop)

    opts = settings |> Map.from_struct() |> Keyword.new()

    # simulate postgres dashboard role
    {:ok, conn} = opts |> Keyword.put(:username, "postgres") |> Postgrex.start_link()
    {:ok, realtime_conn} = opts |> Keyword.put(:username, "supabase_realtime_admin") |> Postgrex.start_link()

    %{conn: conn, realtime_conn: realtime_conn, settings: settings}
  end

  describe "restrictions" do
    @describetag :requires_supautils_policy_grants

    test "deny create trigger on realtime.messages", %{conn: conn} do
      Postgrex.query!(
        conn,
        "CREATE OR REPLACE FUNCTION public.dummy_function() RETURNS trigger AS $$ BEGIN RETURN NEW; END; $$ LANGUAGE plpgsql",
        []
      )

      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Postgrex.query(
                 conn,
                 "CREATE TRIGGER messages_trigger BEFORE INSERT ON realtime.messages FOR EACH ROW EXECUTE FUNCTION public.dummy_function()",
                 []
               )
    end

    test "deny create trigger on realtime.schema_migrations", %{conn: conn} do
      Postgrex.query!(
        conn,
        "CREATE OR REPLACE FUNCTION public.dummy_function() RETURNS trigger AS $$ BEGIN RETURN NEW; END; $$ LANGUAGE plpgsql",
        []
      )

      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Postgrex.query(
                 conn,
                 "CREATE TRIGGER schema_migrations_trigger BEFORE INSERT ON realtime.schema_migrations FOR EACH ROW EXECUTE FUNCTION public.dummy_function()",
                 []
               )
    end

    test "deny create trigger on realtime.subscription", %{conn: conn} do
      Postgrex.query!(
        conn,
        """
        CREATE OR REPLACE FUNCTION public.test_function() RETURNS trigger
        LANGUAGE plpgsql SECURITY INVOKER AS $$
        BEGIN
          RETURN NEW;
        END $$
        """,
        []
      )

      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Postgrex.query(
                 conn,
                 "CREATE TRIGGER test_trigger AFTER INSERT OR UPDATE OR DELETE ON realtime.subscription FOR EACH ROW EXECUTE FUNCTION public.test_function()",
                 []
               )
    end

    test "supabase_realtime_admin cannot grant super to postgres", %{realtime_conn: realtime_conn} do
      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Postgrex.query(realtime_conn, "ALTER ROLE postgres WITH SUPERUSER", [])
    end

    test "deny alter function owner to postgres", %{conn: conn} do
      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Postgrex.query(
                 conn,
                 "ALTER FUNCTION realtime.send(jsonb, text, text, boolean) OWNER TO postgres",
                 []
               )
    end

    test "deny create on realtime schema", %{conn: conn} do
      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Postgrex.query(conn, "CREATE TABLE realtime.new_table (id int)", [])
    end

    test "postgres is not a member of supabase_realtime_admin", %{conn: conn} do
      assert %Postgrex.Result{rows: [[false]]} =
               Postgrex.query!(conn, "SELECT pg_has_role('postgres', 'supabase_realtime_admin', 'MEMBER')", [])
    end

    test "postgres cannot modify realtime.schema_migrations", %{conn: conn} do
      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Postgrex.query(
                 conn,
                 "INSERT INTO realtime.schema_migrations (version, inserted_at) VALUES (0, now())",
                 []
               )

      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Postgrex.query(conn, "DELETE FROM realtime.schema_migrations", [])
    end

    test "postgres cannot create policy on realtime.schema_migrations", %{conn: conn} do
      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Postgrex.query(
                 conn,
                 "CREATE POLICY sm_policy ON realtime.schema_migrations FOR SELECT TO authenticated USING (true)",
                 []
               )
    end
  end

  describe "privileges" do
    test "postgres can grant USAGE on schema realtime to a custom role", %{conn: conn} do
      Postgrex.query!(conn, "CREATE ROLE role_test", [])

      assert {:ok, _} = Postgrex.query(conn, "GRANT USAGE ON SCHEMA realtime TO role_test", [])

      assert %Postgrex.Result{rows: [[true]]} =
               Postgrex.query!(conn, "SELECT has_schema_privilege('role_test', 'realtime', 'USAGE')", [])

      Postgrex.query!(conn, "REVOKE USAGE ON SCHEMA realtime FROM role_test", [])
      Postgrex.query!(conn, "DROP ROLE role_test", [])
    end

    test "supabase_realtime_admin can create a role", %{realtime_conn: realtime_conn} do
      role = "role_realtime_admin_create_#{System.unique_integer([:positive])}"

      assert {:ok, _} = Postgrex.query(realtime_conn, "CREATE ROLE #{role}", [])

      assert %Postgrex.Result{rows: [[true]]} =
               Postgrex.query!(realtime_conn, "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1)", [role])
    end

    test "supabase_realtime_admin has NOINHERIT", %{realtime_conn: realtime_conn} do
      assert %Postgrex.Result{rows: [[false]]} =
               Postgrex.query!(
                 realtime_conn,
                 "SELECT rolinherit FROM pg_roles WHERE rolname = 'supabase_realtime_admin'",
                 []
               )
    end

    test "supabase_realtime_admin can SET ROLE to granted roles", %{realtime_conn: realtime_conn} do
      for role <- ~w(anon authenticated service_role) do
        assert {:ok, _} = Postgrex.query(realtime_conn, "SET ROLE #{role}", [])
        Postgrex.query!(realtime_conn, "RESET ROLE", [])
      end
    end

    test "supabase_realtime_admin can drop a role", %{realtime_conn: realtime_conn} do
      role = "role_realtime_admin_drop_#{System.unique_integer([:positive])}"
      Postgrex.query!(realtime_conn, "CREATE ROLE #{role}", [])

      assert {:ok, _} = Postgrex.query(realtime_conn, "DROP ROLE #{role}", [])

      assert %Postgrex.Result{rows: [[false]]} =
               Postgrex.query!(realtime_conn, "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1)", [role])
    end

    test "insert into realtime.messages", %{conn: conn} do
      assert {:ok, %Postgrex.Result{num_rows: 1}} =
               Postgrex.query(
                 conn,
                 "INSERT INTO realtime.messages (payload, event, topic, private, extension) VALUES ($1, $2, $3, $4, $5)",
                 [%{"hello" => "world"}, "test_event", "test_topic", false, "broadcast"]
               )
    end
  end

  describe "ownership" do
    test "all objects in realtime schema are owned by supabase_realtime_admin", %{conn: conn} do
      query = """
      SELECT r.rolname FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_roles r ON r.oid = c.relowner
      WHERE n.nspname = 'realtime' AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
        AND c.relname <> 'schema_migrations'
      UNION
      SELECT r.rolname FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      JOIN pg_roles r ON r.oid = p.proowner
      WHERE n.nspname = 'realtime'
      UNION
      SELECT r.rolname FROM pg_type t
      JOIN pg_namespace n ON n.oid = t.typnamespace
      JOIN pg_roles r ON r.oid = t.typowner
      WHERE n.nspname = 'realtime' AND t.typtype IN ('b', 'd', 'e', 'r', 'm')
        AND t.typname <> '_schema_migrations'
      """

      assert %Postgrex.Result{rows: [["supabase_realtime_admin"]]} = Postgrex.query!(conn, query, [])
    end

    test "realtime schema is owned by supabase_admin", %{conn: conn} do
      assert %Postgrex.Result{rows: [["supabase_admin"]]} =
               Postgrex.query!(
                 conn,
                 "SELECT r.rolname FROM pg_namespace n JOIN pg_roles r ON r.oid = n.nspowner WHERE n.nspname = 'realtime'",
                 []
               )
    end
  end

  describe "realtime.messages policy grants" do
    test "create and drop SELECT policy", %{conn: conn} do
      assert {:ok, _} =
               Postgrex.query(
                 conn,
                 "CREATE POLICY messages_policy_select_test ON realtime.messages FOR SELECT TO authenticated USING (true)",
                 []
               )

      assert {:ok, _} = Postgrex.query(conn, "DROP POLICY messages_policy_select_test ON realtime.messages", [])
    end

    test "create and drop INSERT policy", %{conn: conn} do
      assert {:ok, _} =
               Postgrex.query(
                 conn,
                 "CREATE POLICY messages_policy_insert_test ON realtime.messages FOR INSERT TO authenticated WITH CHECK (true)",
                 []
               )

      assert {:ok, _} = Postgrex.query(conn, "DROP POLICY messages_policy_insert_test ON realtime.messages", [])
    end

    test "create and drop FOR ALL policy", %{conn: conn} do
      assert {:ok, _} =
               Postgrex.query(
                 conn,
                 "CREATE POLICY messages_policy ON realtime.messages FOR ALL TO authenticated USING (true) WITH CHECK (true)",
                 []
               )

      assert {:ok, _} = Postgrex.query(conn, "DROP POLICY messages_policy ON realtime.messages", [])
    end

    test "alter existing policy", %{conn: conn} do
      Postgrex.query!(
        conn,
        "CREATE POLICY messages_policy_alter_test ON realtime.messages FOR SELECT TO authenticated USING (true)",
        []
      )

      assert {:ok, _} =
               Postgrex.query(
                 conn,
                 "ALTER POLICY messages_policy_alter_test ON realtime.messages USING (auth.role() = 'authenticated')",
                 []
               )

      Postgrex.query!(conn, "DROP POLICY messages_policy_alter_test ON realtime.messages", [])
    end
  end

  describe "realtime.subscription policy grants" do
    test "create and drop SELECT policy", %{conn: conn} do
      assert {:ok, _} =
               Postgrex.query(
                 conn,
                 "CREATE POLICY subscription_policy_select ON realtime.subscription FOR SELECT TO authenticated USING (true)",
                 []
               )

      assert {:ok, _} = Postgrex.query(conn, "DROP POLICY subscription_policy_select ON realtime.subscription", [])
    end

    test "create and drop INSERT policy", %{conn: conn} do
      assert {:ok, _} =
               Postgrex.query(
                 conn,
                 "CREATE POLICY subscription_policy_insert ON realtime.subscription FOR INSERT TO authenticated WITH CHECK (true)",
                 []
               )

      assert {:ok, _} = Postgrex.query(conn, "DROP POLICY subscription_policy_insert ON realtime.subscription", [])
    end

    test "create and drop UPDATE policy", %{conn: conn} do
      assert {:ok, _} =
               Postgrex.query(
                 conn,
                 "CREATE POLICY subscription_policy_update ON realtime.subscription FOR UPDATE TO authenticated USING (true)",
                 []
               )

      assert {:ok, _} = Postgrex.query(conn, "DROP POLICY subscription_policy_update ON realtime.subscription", [])
    end

    test "create and drop DELETE policy", %{conn: conn} do
      assert {:ok, _} =
               Postgrex.query(
                 conn,
                 "CREATE POLICY subscription_policy_delete ON realtime.subscription FOR DELETE TO authenticated USING (true)",
                 []
               )

      assert {:ok, _} = Postgrex.query(conn, "DROP POLICY subscription_policy_delete ON realtime.subscription", [])
    end

    test "create and drop FOR ALL policy", %{conn: conn} do
      assert {:ok, _} =
               Postgrex.query(
                 conn,
                 "CREATE POLICY subscription_policy_all ON realtime.subscription FOR ALL TO authenticated USING (true) WITH CHECK (true)",
                 []
               )

      assert {:ok, _} = Postgrex.query(conn, "DROP POLICY subscription_policy_all ON realtime.subscription", [])
    end

    test "alter existing policy", %{conn: conn} do
      Postgrex.query!(
        conn,
        "CREATE POLICY subscription_policy_alter_test ON realtime.subscription FOR SELECT TO authenticated USING (true)",
        []
      )

      assert {:ok, _} =
               Postgrex.query(
                 conn,
                 "ALTER POLICY subscription_policy_alter_test ON realtime.subscription USING (auth.role() = 'authenticated')",
                 []
               )

      Postgrex.query!(conn, "DROP POLICY subscription_policy_alter_test ON realtime.subscription", [])
    end
  end
end
