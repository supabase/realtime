defmodule Realtime.Extensions.PostgresCdcRls.SubscriptionsTest do
  use RealtimeWeb.ChannelCase, async: true

  doctest Extensions.PostgresCdcRls.Subscriptions, import: true

  import ExUnit.CaptureLog

  alias Extensions.PostgresCdcRls.Subscriptions
  alias Realtime.Database

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)

    {:ok, db_settings} = Database.from_tenant(tenant, "realtime_rls")

    {:ok, conn} =
      db_settings
      |> Map.from_struct()
      |> Keyword.new()
      |> Postgrex.start_link()

    Integrations.setup_postgres_changes(conn)
    Subscriptions.delete_all(conn)
    assert %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])

    %{conn: conn, tenant: tenant}
  end

  describe "subscribing with row filters" do
    test "user can combine two range conditions to create a bounded filter" do
      assert {:ok, {"*", "public", "test", filters, _}} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "test",
                 "filter" => "id=gt.0,id=lt.100"
               })

      assert [{"id", "gt", "0"}, {"id", "lt", "100"}] = Enum.sort(filters)
    end

    test "user gets a clear error when one filter in a multi-filter expression is unsupported" do
      assert {:error, msg} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "test",
                 "filter" => "id=gt.0,id=like.100"
               })

      assert msg =~ "Error parsing `filter` params"
    end

    test "user can omit the filter value entirely to subscribe to all rows" do
      assert {:ok, {"*", "public", "test", [], _}} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "test",
                 "filter" => ""
               })
    end

    test "user can filter by a single equality condition" do
      assert {:ok, {"*", "public", "test", [{"id", "eq", "5"}], _}} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "test",
                 "filter" => "id=eq.5"
               })
    end

    test "user can combine an in-list filter with an equality filter" do
      assert {:ok, {"*", "public", "test", filters, _}} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "test",
                 "filter" => "id=in.(1,2,3),details=eq.active"
               })

      assert [{"details", "eq", "active"}, {"id", "in", "{1,2,3}"}] = Enum.sort(filters)
    end

    test "user can use an in-list filter with multi-word string values alongside another filter" do
      assert {:ok, {"*", "public", "test", filters, _}} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "test",
                 "filter" => "name=in.(red,blue),quantity=gt.0"
               })

      assert [{"name", "in", "{red,blue}"}, {"quantity", "gt", "0"}] = filters
    end

    test "user can place an in-list filter after a range filter" do
      assert {:ok, {"*", "public", "test", filters, _}} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "test",
                 "filter" => "quantity=gt.0,name=in.(red,blue)"
               })

      assert [{"quantity", "gt", "0"}, {"name", "in", "{red,blue}"}] = filters
    end

    test "user can combine two in-list filters each with multiple values" do
      assert {:ok, {"*", "public", "test", filters, _}} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "test",
                 "filter" => "name=in.(red,blue,green),status=in.(active,inactive)"
               })

      assert [{"name", "in", "{red,blue,green}"}, {"status", "in", "{active,inactive}"}] = filters
    end

    test "user can use filter values that contain a closing parenthesis character" do
      assert {:ok, {"*", "public", "test", filters, _}} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "test",
                 "filter" => "a=eq.x),b=eq.y),c=eq.z"
               })

      assert [{"a", "eq", "x)"}, {"b", "eq", "y)"}, {"c", "eq", "z"}] = filters
    end

    test "user gets a clear error when the filter string ends with a stray comma" do
      assert {:error, msg} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "test",
                 "filter" => "id=gt.0,"
               })

      assert msg =~ "empty segments"
    end

    test "user gets a clear error when the filter string starts with a stray comma" do
      assert {:error, msg} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "test",
                 "filter" => ",id=gt.0"
               })

      assert msg =~ "empty segments"
    end

    test "user gets a clear error when two commas appear back-to-back in a filter string" do
      assert {:error, msg} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "test",
                 "filter" => "a=eq.1,,b=eq.2"
               })

      assert msg =~ "empty segments"
    end

    test "whitespace-only filter string is treated the same as no filter" do
      assert {:ok, {"*", "public", "test", [], _}} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "test",
                 "filter" => "   "
               })
    end
  end

  describe "subscribing to table changes" do
    test "user can subscribe to all events on all tables in a schema", %{conn: conn} do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{"event" => "*", "schema" => "public"})

      params_list = [
        %{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}
      ]

      assert {:ok, [%Postgrex.Result{}]} =
               Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())

      %Postgrex.Result{rows: [[[], "*"]]} =
        Postgrex.query!(conn, "select filters, action_filter from realtime.subscription", [])
    end

    test "user can subscribe to only INSERT events", %{conn: conn} do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{"event" => "INSERT", "schema" => "public"})

      params_list = [
        %{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}
      ]

      assert {:ok, [%Postgrex.Result{}]} =
               Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())

      %Postgrex.Result{rows: [[[], "INSERT"]]} =
        Postgrex.query!(conn, "select filters, action_filter from realtime.subscription", [])
    end

    test "user can subscribe to a specific table", %{conn: conn} do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{"schema" => "public", "table" => "test"})

      subscription_list = [
        %{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}
      ]

      assert {:ok, [%Postgrex.Result{}]} =
               Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())

      %Postgrex.Result{rows: [[1]]} =
        Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end

    test "create works for a table whose name contains a backslash", %{conn: conn} do
      Postgrex.query!(conn, ~s|CREATE TABLE "my\\table" (id int)|, [])
      Postgrex.query!(conn, ~s|GRANT ALL ON "my\\table" TO anon|, [])

      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{"schema" => "public", "table" => "my\\table"})

      subscription_list = [
        %{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}
      ]

      assert {:ok, [%Postgrex.Result{num_rows: 1}]} =
               Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())
    end

    test "user gets an error when Realtime is not enabled for the publication", %{conn: conn} do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{"schema" => "public", "table" => "test"})

      subscription_list = [
        %{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}
      ]

      Postgrex.query!(conn, "drop publication if exists supabase_realtime_test", [])

      assert {:error,
              {:subscription_insert_failed,
               "Unable to subscribe to changes with given parameters. Please check Realtime is enabled for the given connect parameters: [event: *, schema: public, table: test, filters: [], select: nil]"}} =
               Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())

      %Postgrex.Result{rows: [[0]]} =
        Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end

    test "user gets an error when subscribing to a table that does not exist", %{conn: conn} do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{
          "schema" => "public",
          "table" => "doesnotexist"
        })

      subscription_list = [
        %{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}
      ]

      assert {:error,
              {:subscription_insert_failed,
               "Unable to subscribe to changes with given parameters. Please check Realtime is enabled for the given connect parameters: [event: *, schema: public, table: doesnotexist, filters: [], select: nil]"}} =
               Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())

      %Postgrex.Result{rows: [[0]]} =
        Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end

    test "user gets an error when filtering on a column that does not exist", %{conn: conn} do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{
          "schema" => "public",
          "table" => "test",
          "filter" => "subject=eq.hey"
        })

      subscription_list = [
        %{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}
      ]

      assert {:error,
              {:subscription_insert_failed,
               "Unable to subscribe to changes with given parameters. An exception happened so please check your connect parameters: [event: *, schema: public, table: test, filters: [{\"subject\", \"eq\", \"hey\"}], select: nil]. Exception: ERROR P0001 (raise_exception) invalid column for filter subject"}} =
               Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())

      %Postgrex.Result{rows: [[0]]} =
        Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end

    test "user gets an error when filter value is incompatible with column type", %{conn: conn} do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{
          "schema" => "public",
          "table" => "test",
          "filter" => "id=eq.hey"
        })

      subscription_list = [
        %{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}
      ]

      assert {:error,
              {:subscription_insert_failed,
               "Unable to subscribe to changes with given parameters. An exception happened so please check your connect parameters: [event: *, schema: public, table: test, filters: [{\"id\", \"eq\", \"hey\"}], select: nil]. Exception: ERROR 22P02 (invalid_text_representation) invalid input syntax for type integer: \"hey\""}} =
               Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())

      %Postgrex.Result{rows: [[0]]} =
        Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end

    test "subscription creation fails gracefully when database connection is dead" do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{"schema" => "public", "table" => "test"})

      subscription_list = [
        %{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}
      ]

      conn = spawn(fn -> :ok end)

      assert {:error, {:exit, _}} =
               Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())
    end

    test "subscription creation fails gracefully when the connection pool is exhausted", %{
      conn: conn
    } do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{"schema" => "public", "table" => "test"})

      Task.start(fn -> Postgrex.query!(conn, "SELECT pg_sleep(11)", []) end)

      subscription_list = [
        %{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}
      ]

      assert {:error, %DBConnection.ConnectionError{reason: :queue_timeout}} =
               Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())
    end

    test "user gets an error when table param is not a string" do
      {:error, msg} =
        Subscriptions.parse_subscription_params(%{
          "schema" => "public",
          "table" => %{"actually a" => "map"}
        })

      assert msg =~ "No subscription params provided"
    end

    test "user gets an error when schema param is not a string" do
      {:error, msg} =
        Subscriptions.parse_subscription_params(%{
          "table" => "images",
          "schema" => %{"actually a" => "map"}
        })

      assert msg =~ "No subscription params provided"
    end

    test "user gets an error when filter param is not a string" do
      {:error, msg} =
        Subscriptions.parse_subscription_params(%{
          "schema" => "public",
          "table" => "images",
          "filter" => [123]
        })

      assert msg =~ "No subscription params provided"
    end

    test "user can combine AND row filters which are all stored in the subscription", %{
      conn: conn
    } do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{
          "schema" => "public",
          "table" => "test",
          "filter" => "id=gt.0,id=lt.100"
        })

      params_list = [
        %{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}
      ]

      assert {:ok, [%Postgrex.Result{}]} =
               Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())

      assert %Postgrex.Result{rows: [[filters]]} =
               Postgrex.query!(conn, "select filters from realtime.subscription", [])

      assert [_, _] = filters
    end
  end

  describe "delete_all/1" do
    test "delete_all", %{conn: conn} do
      create_subscriptions(conn, 10)
      assert :ok = Subscriptions.delete_all(conn)
      assert %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end

    test "returns ok when connection is unavailable" do
      conn = spawn(fn -> :ok end)
      assert :ok = Subscriptions.delete_all(conn)
    end

    test "logs error when subscription table is dropped", %{conn: conn} do
      Postgrex.query!(conn, "drop table if exists realtime.subscription cascade", [])

      log = capture_log(fn -> Subscriptions.delete_all(conn) end)
      assert log =~ "SubscriptionDeletionFailed"
    end
  end

  describe "delete/2" do
    test "returns error when subscription table is dropped", %{conn: conn} do
      Postgrex.query!(conn, "drop table if exists realtime.subscription cascade", [])

      assert {:error, %Postgrex.Error{}} = Subscriptions.delete(conn, UUID.string_to_binary!(UUID.uuid1()))
    end

    test "delete", %{conn: conn} do
      id = UUID.uuid1()
      bin_id = UUID.string_to_binary!(id)

      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{
          "schema" => "public",
          "table" => "test",
          "filter" => "id=eq.hey"
        })

      subscription_list = [%{claims: %{"role" => "anon"}, id: id, subscription_params: subscription_params}]
      Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())

      assert {:ok, %Postgrex.Result{}} = Subscriptions.delete(conn, bin_id)
      assert %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end

    test "returns error when connection is unavailable" do
      conn = spawn(fn -> :ok end)
      assert {:error, _} = Subscriptions.delete(conn, UUID.uuid1())
    end
  end

  describe "delete_multi/2" do
    test "delete_multi", %{conn: conn} do
      Subscriptions.delete_all(conn)
      id1 = UUID.uuid1()
      id2 = UUID.uuid1()

      bin_id2 = UUID.string_to_binary!(id2)
      bin_id1 = UUID.string_to_binary!(id1)

      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{
          "schema" => "public",
          "table" => "test",
          "filter" => "id=eq.123"
        })

      subscription_list = [
        %{claims: %{"role" => "anon"}, id: id1, subscription_params: subscription_params},
        %{claims: %{"role" => "anon"}, id: id2, subscription_params: subscription_params}
      ]

      assert {:ok, _} = Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())

      assert %Postgrex.Result{rows: [[2]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
      assert {:ok, %Postgrex.Result{}} = Subscriptions.delete_multi(conn, [bin_id1, bin_id2])
      assert %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end
  end

  describe "delete_all_if_table_exists/1" do
    test "delete_all_if_table_exists", %{conn: conn} do
      Subscriptions.delete_all(conn)
      create_subscriptions(conn, 10)

      assert :ok = Subscriptions.delete_all_if_table_exists(conn)
      assert %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end

    test "logs error when trigger raises on delete", %{conn: conn, tenant: tenant} do
      create_subscriptions(conn, 3)

      Postgrex.query!(
        conn,
        """
          create or replace function realtime.evil_delete_trigger()
          returns trigger language plpgsql as $$
          begin raise exception 'evil trigger'; end;
          $$;
        """,
        []
      )

      Postgrex.query!(
        conn,
        """
          create trigger evil_delete_trigger
          before delete on realtime.subscription
          for each row execute function realtime.evil_delete_trigger();
        """,
        []
      )

      on_exit(fn ->
        {:ok, db_settings} = Database.from_tenant(tenant, "realtime_rls")

        {:ok, cleanup_conn} =
          db_settings
          |> Map.from_struct()
          |> Keyword.new()
          |> Postgrex.start_link()

        Postgrex.query(cleanup_conn, "drop trigger if exists evil_delete_trigger on realtime.subscription", [])
        Postgrex.query(cleanup_conn, "drop function if exists realtime.evil_delete_trigger()", [])
        GenServer.stop(cleanup_conn)
      end)

      log = capture_log(fn -> Subscriptions.delete_all_if_table_exists(conn) end)
      assert log =~ "SubscriptionCleanupFailed"
    end

    test "logs error when connection is dead" do
      conn = spawn(fn -> :ok end)
      log = capture_log(fn -> Subscriptions.delete_all_if_table_exists(conn) end)
      assert log =~ "SubscriptionCleanupFailed"
    end
  end

  describe "fetch_publication_tables/2" do
    test "fetch_publication_tables", %{conn: conn} do
      tables = Subscriptions.fetch_publication_tables(conn, "supabase_realtime_test")
      assert tables[{"*"}] != nil
    end
  end

  describe "existing subscriptions without column selection continue to receive full payloads" do
    test "omitting select returns all columns (no behavior change for existing clients)" do
      assert {:ok, {"*", "public", "messages", [], nil}} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "messages"
               })
    end

    test "passing an empty select list is treated as no column selection" do
      assert {:ok, {"*", "public", "messages", [], nil}} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "messages",
                 "select" => []
               })
    end

    test "subscription without select stores NULL in the database (no column restriction)", %{
      conn: conn
    } do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{"schema" => "public", "table" => "test"})

      params_list = [
        %{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}
      ]

      assert {:ok, [%Postgrex.Result{}]} =
               Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())

      assert %Postgrex.Result{rows: [[nil]]} =
               Postgrex.query!(conn, "select selected_columns from realtime.subscription", [])
    end

    test "apply_rls returns all columns in the payload when no column selection is set", %{
      conn: conn
    } do
      sub_id = UUID.uuid1()
      slot_name = "test_apply_rls_no_select_#{:rand.uniform(999_999)}"

      Postgrex.query!(
        conn,
        "insert into realtime.subscription (subscription_id, entity, claims) values ($1::text::uuid, 'public.test'::regclass, $2)",
        [sub_id, %{"role" => "anon"}]
      )

      Postgrex.query!(conn, "SELECT pg_create_logical_replication_slot($1, 'wal2json')", [slot_name])

      try do
        Postgrex.query!(conn, "insert into test (details) values ('hello')", [])

        %{rows: rows} =
          Postgrex.query!(
            conn,
            "select wal, subscription_ids from realtime.list_changes($1, $2, 100, 1048576)",
            ["supabase_realtime_test", slot_name]
          )

        # apply_rls stores subscription_ids as binary UUIDs
        bin_sub_id = UUID.string_to_binary!(sub_id)
        matching = Enum.find(rows, fn [_wal, sub_ids] -> bin_sub_id in (sub_ids || []) end)
        assert matching != nil, "Expected sub_id in list_changes result. rows=#{inspect(rows)}"
        [wal_result, _] = matching
        assert Map.has_key?(wal_result["record"], "id")
        assert Map.has_key?(wal_result["record"], "details")
      after
        Postgrex.query(conn, "SELECT pg_drop_replication_slot($1)", [slot_name])
      end
    end
  end

  describe "subscribing with column selection (select param)" do
    test "user can pass a list of column names to limit the payload" do
      assert {:ok, {"*", "public", "messages", [], ["id", "details"]}} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "messages",
                 "select" => ["id", "details"]
               })
    end

    test "passing a string to select is rejected with a clear error message" do
      assert {:error, msg} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "messages",
                 "select" => "id,details"
               })

      assert msg =~ "`select`"
    end

    test "non-binary entries in a select list are silently dropped" do
      assert {:ok, {"*", "public", "messages", [], ["id", "details"]}} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "messages",
                 "select" => ["id", 123, "details", nil]
               })
    end

    test "passing any string value to select is rejected" do
      assert {:error, msg} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "messages",
                 "select" => ""
               })

      assert msg =~ "`select`"
    end

    test "user can combine column selection with a row filter" do
      assert {:ok, {"*", "public", "messages", [{"id", "eq", "5"}], ["id", "details"]}} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "messages",
                 "filter" => "id=eq.5",
                 "select" => ["id", "details"]
               })
    end

    test "selected columns are stored in normalized (sorted) order in the database", %{
      conn: conn
    } do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{
          "schema" => "public",
          "table" => "test",
          "select" => ["details", "id"]
        })

      params_list = [
        %{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}
      ]

      assert {:ok, [%Postgrex.Result{}]} =
               Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())

      assert %Postgrex.Result{rows: [[selected_columns]]} =
               Postgrex.query!(conn, "select selected_columns from realtime.subscription", [])

      assert ["details", "id"] = Enum.sort(selected_columns)
    end

    test "two subscriptions on the same table with different column selections are stored as separate rows",
         %{conn: conn} do
      id = UUID.uuid1()

      {:ok, params1} =
        Subscriptions.parse_subscription_params(%{
          "schema" => "public",
          "table" => "test",
          "select" => ["id"]
        })

      {:ok, params2} =
        Subscriptions.parse_subscription_params(%{
          "schema" => "public",
          "table" => "test",
          "select" => ["id", "details"]
        })

      params_list = [
        %{claims: %{"role" => "anon"}, id: id, subscription_params: params1},
        %{claims: %{"role" => "anon"}, id: id, subscription_params: params2}
      ]

      assert {:ok, [%Postgrex.Result{}, %Postgrex.Result{}]} =
               Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())

      assert %Postgrex.Result{rows: [[2]]} =
               Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end

    test "user gets an error when select references a column that does not exist", %{conn: conn} do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{
          "schema" => "public",
          "table" => "test",
          "select" => ["nonexistent_column"]
        })

      params_list = [
        %{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}
      ]

      assert {:error, {:subscription_insert_failed, msg}} =
               Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())

      assert msg =~ "invalid column for select nonexistent_column"
    end

    test "user gets an error when using select with a schema-only (wildcard table) subscription" do
      assert {:error, msg} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "select" => ["id"]
               })

      assert msg =~ "wildcard"
    end

    test "user gets an error when using select with an explicit wildcard table" do
      assert {:error, msg} =
               Subscriptions.parse_subscription_params(%{
                 "schema" => "public",
                 "table" => "*",
                 "select" => ["id"]
               })

      assert msg =~ "wildcard"
    end
  end

  defp create_subscriptions(conn, num) do
    params_list =
      Enum.reduce(1..num, [], fn _i, acc ->
        [
          %{
            claims: %{
              "exp" => 1_974_176_791,
              "iat" => 1_658_600_791,
              "iss" => "supabase",
              "ref" => "127.0.0.1",
              "role" => "anon"
            },
            id: UUID.uuid1(),
            subscription_params: {"*", "public", "*", [], nil}
          }
          | acc
        ]
      end)

    Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())
  end
end
