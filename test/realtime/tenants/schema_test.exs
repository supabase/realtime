defmodule Realtime.Tenants.SchemaTest do
  # Validates the permissions on each Postgres major version supported by Realtime
  #
  # - tag `@describetag :requires_supautils_policy_grants` are the images supabase/postgres >= 15.14.1.018 where policy is managed by supautils.policy_grants
  # - tag `@describetag :requires_no_supautils_policy_grants` represents older images where schema restrictions can't be applied
  # - untagged tests assert behaviour on every version

  use Realtime.DataCase, async: false
  alias Realtime.Database

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    {:ok, settings} = Database.from_tenant(tenant, "realtime_test", :stop)
    opts = settings |> Map.from_struct() |> Keyword.new()

    {:ok, conn_postgres} = opts |> Keyword.put(:username, "postgres") |> Postgrex.start_link()
    {:ok, conn_superuser} = opts |> Keyword.put(:username, "supabase_admin") |> Postgrex.start_link()

    %{conn_postgres: conn_postgres, conn_superuser: conn_superuser, settings: settings}
  end

  describe "postgres role restrictions on realtime schema" do
    @describetag :requires_supautils_policy_grants

    test "not a member of supabase_realtime_admin", %{conn_postgres: conn_postgres} do
      assert %Postgrex.Result{rows: [[false]]} =
               Postgrex.query!(conn_postgres, "SELECT pg_has_role('postgres', 'supabase_realtime_admin', 'MEMBER')", [])
    end

    test "cannot assume supabase_realtime_admin", %{conn_postgres: conn_postgres} do
      assert_denied(conn_postgres, "SET ROLE supabase_realtime_admin")
    end

    test "cannot drop any object", %{conn_postgres: conn_postgres} do
      %Postgrex.Result{rows: rows} =
        Postgrex.query!(
          conn_postgres,
          """
          SELECT format('DROP TABLE %I.%I', n.nspname, c.relname)
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'realtime' AND c.relkind IN ('r', 'p')
          UNION ALL
          SELECT format('DROP SEQUENCE %I.%I', n.nspname, c.relname)
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'realtime' AND c.relkind = 'S'
          UNION ALL
          SELECT format('DROP %s %s',
            CASE p.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE' ELSE 'FUNCTION' END,
            p.oid::regprocedure::text)
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'realtime'
          UNION ALL
          SELECT format('DROP TYPE %I.%I', n.nspname, t.typname)
          FROM pg_type t
          JOIN pg_namespace n ON n.oid = t.typnamespace
          WHERE n.nspname = 'realtime'
            AND (t.typtype = 'e'
                 OR (t.typtype = 'c' AND EXISTS (
                   SELECT 1 FROM pg_class c WHERE c.oid = t.typrelid AND c.relkind = 'c'
                 )))
          """,
          []
        )

      for object <- List.flatten(rows), do: assert_denied(conn_postgres, object)
    end

    test "cannot drop schema realtime", %{conn_postgres: conn_postgres} do
      assert_denied(conn_postgres, "DROP SCHEMA realtime CASCADE")
    end

    test "cannot create a table", %{conn_postgres: conn_postgres} do
      assert_denied(conn_postgres, "CREATE TABLE realtime.new_table (id int)")
    end

    test "cannot create a function", %{conn_postgres: conn_postgres} do
      assert_denied(conn_postgres, "CREATE FUNCTION realtime.evil() RETURNS void LANGUAGE sql AS 'SELECT 1'")
    end

    test "cannot create a trigger on realtime tables", %{conn_postgres: conn_postgres} do
      Postgrex.query!(
        conn_postgres,
        "CREATE OR REPLACE FUNCTION public.dummy_function() RETURNS trigger AS $$ BEGIN RETURN NEW; END; $$ LANGUAGE plpgsql",
        []
      )

      for table <- ~w(messages subscription) do
        assert_denied(
          conn_postgres,
          "CREATE TRIGGER #{table}_trigger BEFORE INSERT ON realtime.#{table} FOR EACH ROW EXECUTE FUNCTION public.dummy_function()"
        )
      end
    end

    test "cannot alter realtime.messages columns", %{conn_postgres: conn_postgres} do
      assert_denied(conn_postgres, "ALTER TABLE realtime.messages ADD COLUMN evil int")
      assert_denied(conn_postgres, "ALTER TABLE realtime.messages DROP COLUMN payload")
      assert_denied(conn_postgres, "ALTER TABLE realtime.messages RENAME COLUMN payload TO evil")
    end

    test "cannot alter a function owner to postgres", %{conn_postgres: conn_postgres} do
      assert_denied(conn_postgres, "ALTER FUNCTION realtime.send(jsonb, text, text, boolean) OWNER TO postgres")
    end

    test "cannot rename realtime.messages", %{conn_postgres: conn_postgres} do
      assert_denied(conn_postgres, "ALTER TABLE realtime.messages RENAME TO evil_messages")
    end
  end

  describe "postgres role allowances on realtime schema" do
    test "has USAGE on schema realtime", %{conn_postgres: conn_postgres} do
      assert %Postgrex.Result{rows: [[true]]} =
               Postgrex.query!(conn_postgres, "SELECT has_schema_privilege('postgres', 'realtime', 'USAGE')", [])
    end

    test "can grant USAGE on schema realtime to a custom role", %{conn_postgres: conn_postgres} do
      Postgrex.query!(conn_postgres, "CREATE ROLE role_test", [])

      assert {:ok, _} = Postgrex.query(conn_postgres, "GRANT USAGE ON SCHEMA realtime TO role_test", [])

      assert %Postgrex.Result{rows: [[true]]} =
               Postgrex.query!(conn_postgres, "SELECT has_schema_privilege('role_test', 'realtime', 'USAGE')", [])

      Postgrex.query!(conn_postgres, "REVOKE USAGE ON SCHEMA realtime FROM role_test", [])
      Postgrex.query!(conn_postgres, "DROP ROLE role_test", [])
    end

    test "can insert into realtime.messages", %{conn_postgres: conn_postgres} do
      assert {:ok, %Postgrex.Result{num_rows: 1}} =
               Postgrex.query(
                 conn_postgres,
                 "INSERT INTO realtime.messages (payload, event, topic, private, extension) VALUES ($1, $2, $3, $4, $5)",
                 [%{"hello" => "world"}, "test_event", "test_topic", false, "broadcast"]
               )
    end

    test "can select from realtime.messages", %{conn_postgres: conn_postgres} do
      assert {:ok, _} = Postgrex.query(conn_postgres, "SELECT * FROM realtime.messages LIMIT 1", [])
    end
  end

  describe "realtime.messages policy grants" do
    test "create and drop SELECT policy", %{conn_postgres: conn_postgres} do
      assert {:ok, _} =
               Postgrex.query(
                 conn_postgres,
                 "CREATE POLICY messages_policy_select_test ON realtime.messages FOR SELECT TO authenticated USING (true)",
                 []
               )

      assert {:ok, _} =
               Postgrex.query(conn_postgres, "DROP POLICY messages_policy_select_test ON realtime.messages", [])
    end

    test "create and drop INSERT policy", %{conn_postgres: conn_postgres} do
      assert {:ok, _} =
               Postgrex.query(
                 conn_postgres,
                 "CREATE POLICY messages_policy_insert_test ON realtime.messages FOR INSERT TO authenticated WITH CHECK (true)",
                 []
               )

      assert {:ok, _} =
               Postgrex.query(conn_postgres, "DROP POLICY messages_policy_insert_test ON realtime.messages", [])
    end

    test "create and drop FOR ALL policy", %{conn_postgres: conn_postgres} do
      assert {:ok, _} =
               Postgrex.query(
                 conn_postgres,
                 "CREATE POLICY messages_policy ON realtime.messages FOR ALL TO authenticated USING (true) WITH CHECK (true)",
                 []
               )

      assert {:ok, _} = Postgrex.query(conn_postgres, "DROP POLICY messages_policy ON realtime.messages", [])
    end

    test "alter existing policy", %{conn_postgres: conn_postgres} do
      Postgrex.query!(
        conn_postgres,
        "CREATE POLICY messages_policy_alter_test ON realtime.messages FOR SELECT TO authenticated USING (true)",
        []
      )

      assert {:ok, _} =
               Postgrex.query(
                 conn_postgres,
                 "ALTER POLICY messages_policy_alter_test ON realtime.messages USING (auth.role() = 'authenticated')",
                 []
               )

      Postgrex.query!(conn_postgres, "DROP POLICY messages_policy_alter_test ON realtime.messages", [])
    end
  end

  describe "realtime.subscription policy grants" do
    @describetag :requires_supautils_policy_grants

    test "create and drop SELECT policy", %{conn_postgres: conn_postgres} do
      assert {:ok, _} =
               Postgrex.query(
                 conn_postgres,
                 "CREATE POLICY subscription_policy_select ON realtime.subscription FOR SELECT TO authenticated USING (true)",
                 []
               )

      assert {:ok, _} =
               Postgrex.query(conn_postgres, "DROP POLICY subscription_policy_select ON realtime.subscription", [])
    end

    test "create and drop INSERT policy", %{conn_postgres: conn_postgres} do
      assert {:ok, _} =
               Postgrex.query(
                 conn_postgres,
                 "CREATE POLICY subscription_policy_insert ON realtime.subscription FOR INSERT TO authenticated WITH CHECK (true)",
                 []
               )

      assert {:ok, _} =
               Postgrex.query(conn_postgres, "DROP POLICY subscription_policy_insert ON realtime.subscription", [])
    end

    test "create and drop UPDATE policy", %{conn_postgres: conn_postgres} do
      assert {:ok, _} =
               Postgrex.query(
                 conn_postgres,
                 "CREATE POLICY subscription_policy_update ON realtime.subscription FOR UPDATE TO authenticated USING (true)",
                 []
               )

      assert {:ok, _} =
               Postgrex.query(conn_postgres, "DROP POLICY subscription_policy_update ON realtime.subscription", [])
    end

    test "create and drop DELETE policy", %{conn_postgres: conn_postgres} do
      assert {:ok, _} =
               Postgrex.query(
                 conn_postgres,
                 "CREATE POLICY subscription_policy_delete ON realtime.subscription FOR DELETE TO authenticated USING (true)",
                 []
               )

      assert {:ok, _} =
               Postgrex.query(conn_postgres, "DROP POLICY subscription_policy_delete ON realtime.subscription", [])
    end

    test "create and drop FOR ALL policy", %{conn_postgres: conn_postgres} do
      assert {:ok, _} =
               Postgrex.query(
                 conn_postgres,
                 "CREATE POLICY subscription_policy_all ON realtime.subscription FOR ALL TO authenticated USING (true) WITH CHECK (true)",
                 []
               )

      assert {:ok, _} =
               Postgrex.query(conn_postgres, "DROP POLICY subscription_policy_all ON realtime.subscription", [])
    end

    test "alter existing policy", %{conn_postgres: conn_postgres} do
      Postgrex.query!(
        conn_postgres,
        "CREATE POLICY subscription_policy_alter_test ON realtime.subscription FOR SELECT TO authenticated USING (true)",
        []
      )

      assert {:ok, _} =
               Postgrex.query(
                 conn_postgres,
                 "ALTER POLICY subscription_policy_alter_test ON realtime.subscription USING (auth.role() = 'authenticated')",
                 []
               )

      Postgrex.query!(conn_postgres, "DROP POLICY subscription_policy_alter_test ON realtime.subscription", [])
    end
  end

  describe "realtime.schema_migrations" do
    test "postgres cannot modify rows", %{conn_postgres: conn_postgres} do
      assert_denied(conn_postgres, "INSERT INTO realtime.schema_migrations (version, inserted_at) VALUES (0, now())")
      assert_denied(conn_postgres, "DELETE FROM realtime.schema_migrations")
      assert_denied(conn_postgres, "UPDATE realtime.schema_migrations SET version = 0")
    end

    test "postgres cannot create a policy", %{conn_postgres: conn_postgres} do
      assert_denied(
        conn_postgres,
        "CREATE POLICY sm_policy ON realtime.schema_migrations FOR SELECT TO authenticated USING (true)"
      )
    end

    test "postgres cannot create a trigger", %{conn_postgres: conn_postgres} do
      Postgrex.query!(
        conn_postgres,
        "CREATE OR REPLACE FUNCTION public.dummy_function() RETURNS trigger AS $$ BEGIN RETURN NEW; END; $$ LANGUAGE plpgsql",
        []
      )

      assert_denied(
        conn_postgres,
        "CREATE TRIGGER schema_migrations_trigger BEFORE INSERT ON realtime.schema_migrations FOR EACH ROW EXECUTE FUNCTION public.dummy_function()"
      )
    end

    test "supabase_admin can write to schema_migrations", %{conn_superuser: conn_superuser} do
      assert {:ok, _} =
               Postgrex.query(
                 conn_superuser,
                 "INSERT INTO realtime.schema_migrations (version, inserted_at) VALUES (1, now())",
                 []
               )

      Postgrex.query!(conn_superuser, "DELETE FROM realtime.schema_migrations WHERE version = 1", [])
    end
  end

  describe "ownership" do
    test "all objects in the realtime schema are owned by supabase_realtime_admin", %{conn_superuser: conn_superuser} do
      query = """
      SELECT format('table %I.%I', n.nspname, c.relname), r.rolname FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_roles r ON r.oid = c.relowner
      WHERE n.nspname = 'realtime' AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
        AND c.relname <> 'schema_migrations'
        AND r.rolname <> 'supabase_realtime_admin'
      UNION ALL
      SELECT format('function %I.%I', n.nspname, p.proname), r.rolname FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      JOIN pg_roles r ON r.oid = p.proowner
      WHERE n.nspname = 'realtime' AND r.rolname <> 'supabase_realtime_admin'
      UNION ALL
      SELECT format('type %I.%I', n.nspname, t.typname), r.rolname FROM pg_type t
      JOIN pg_namespace n ON n.oid = t.typnamespace
      JOIN pg_roles r ON r.oid = t.typowner
      WHERE n.nspname = 'realtime' AND t.typtype IN ('b', 'd', 'e', 'r', 'm')
        AND t.typname <> '_schema_migrations'
        AND r.rolname <> 'supabase_realtime_admin'
      """

      %Postgrex.Result{rows: offenders} = Postgrex.query!(conn_superuser, query, [])

      assert offenders == [],
             "realtime objects not owned by supabase_realtime_admin (add `ALTER ... OWNER TO supabase_realtime_admin` to the migration):\n" <>
               Enum.map_join(offenders, "\n", fn [object, owner] -> "  - #{object} (owned by #{owner})" end)
    end

    test "realtime schema is owned by supabase_admin", %{conn_superuser: conn_superuser} do
      assert %Postgrex.Result{rows: [["supabase_admin"]]} =
               Postgrex.query!(
                 conn_superuser,
                 "SELECT r.rolname FROM pg_namespace n JOIN pg_roles r ON r.oid = n.nspowner WHERE n.nspname = 'realtime'",
                 []
               )
    end
  end

  describe "supabase_admin can still manage realtime objects after the restriction" do
    @describetag :requires_supautils_policy_grants

    test "can alter and revert ownership of a realtime object", %{conn_superuser: conn_superuser} do
      assert {:ok, _} = Postgrex.query(conn_superuser, "ALTER TABLE realtime.messages OWNER TO supabase_admin", [])

      assert {:ok, _} =
               Postgrex.query(conn_superuser, "ALTER TABLE realtime.messages OWNER TO supabase_realtime_admin", [])
    end

    test "can create and drop objects in realtime schema", %{conn_superuser: conn_superuser} do
      assert {:ok, _} = Postgrex.query(conn_superuser, "CREATE TABLE realtime.future_migration_table (id int)", [])
      assert {:ok, _} = Postgrex.query(conn_superuser, "DROP TABLE realtime.future_migration_table", [])
    end
  end

  describe "postgres role on realtime schema without supautils grants" do
    @describetag :requires_no_supautils_policy_grants

    test "is still a member of supabase_realtime_admin", %{conn_postgres: conn_postgres} do
      assert %Postgrex.Result{rows: [[true]]} =
               Postgrex.query!(conn_postgres, "SELECT pg_has_role('postgres', 'supabase_realtime_admin', 'MEMBER')", [])
    end

    test "has CREATE on schema realtime", %{conn_postgres: conn_postgres} do
      assert %Postgrex.Result{rows: [[true]]} =
               Postgrex.query!(conn_postgres, "SELECT has_schema_privilege('postgres', 'realtime', 'CREATE')", [])
    end

    test "can create and drop objects in the realtime schema", %{conn_postgres: conn_postgres} do
      assert_allowed(conn_postgres, "CREATE TABLE realtime.test (id int)")
      assert_allowed(conn_postgres, "DROP TABLE realtime.test")
      assert_allowed(conn_postgres, "CREATE FUNCTION realtime.test() RETURNS void LANGUAGE sql AS 'SELECT 1'")
      assert_allowed(conn_postgres, "DROP FUNCTION realtime.test()")
    end

    test "can create a trigger on realtime tables", %{conn_postgres: conn_postgres} do
      Postgrex.query!(
        conn_postgres,
        "CREATE OR REPLACE FUNCTION public.dummy_function() RETURNS trigger AS $$ BEGIN RETURN NEW; END; $$ LANGUAGE plpgsql",
        []
      )

      for table <- ~w(messages subscription) do
        assert_allowed(
          conn_postgres,
          "CREATE TRIGGER #{table}_trigger BEFORE INSERT ON realtime.#{table} FOR EACH ROW EXECUTE FUNCTION public.dummy_function()"
        )
      end
    end

    test "can assume supabase_realtime_admin to tamper with its objects", %{conn_postgres: conn_postgres} do
      Postgrex.transaction(conn_postgres, fn conn ->
        Postgrex.query!(conn, "SET ROLE supabase_realtime_admin", [])
        assert_allowed(conn, "DROP TABLE realtime.messages CASCADE")
        Postgrex.rollback(conn, :rollback)
      end)
    end
  end

  defp assert_denied(conn, query) do
    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             Postgrex.query(conn, query, []),
           "expected insufficient_privilege for: #{query}"
  end

  defp assert_allowed(conn, query) do
    assert {:ok, _} = Postgrex.query(conn, query, []), "expected query to succeed: #{query}"
  end
end
