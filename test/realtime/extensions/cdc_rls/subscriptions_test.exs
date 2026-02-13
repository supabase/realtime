defmodule Realtime.Extensions.PostgresCdcRls.SubscriptionsTest do
  use RealtimeWeb.ChannelCase, async: true

  doctest Extensions.PostgresCdcRls.Subscriptions, import: true

  alias Extensions.PostgresCdcRls.Subscriptions
  alias Realtime.Database

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)

    {:ok, conn} =
      tenant
      |> Database.from_tenant("realtime_rls")
      |> Map.from_struct()
      |> Keyword.new()
      |> Postgrex.start_link()

    Integrations.setup_postgres_changes(conn)
    Subscriptions.delete_all(conn)
    assert %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])

    %{conn: conn}
  end

  describe "create/5" do
    test "create all tables & all events", %{conn: conn} do
      {:ok, subscription_params} = Subscriptions.parse_subscription_params(%{"event" => "*", "schema" => "public"})
      params_list = [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}]

      assert {:ok, [%Postgrex.Result{}]} =
               Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())

      %Postgrex.Result{rows: [[[], "*"]]} =
        Postgrex.query!(conn, "select filters, action_filter from realtime.subscription", [])
    end

    test "create all tables & all events on INSERT", %{conn: conn} do
      {:ok, subscription_params} = Subscriptions.parse_subscription_params(%{"event" => "INSERT", "schema" => "public"})
      params_list = [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}]

      assert {:ok, [%Postgrex.Result{}]} =
               Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())

      %Postgrex.Result{rows: [[[], "INSERT"]]} =
        Postgrex.query!(conn, "select filters, action_filter from realtime.subscription", [])
    end

    test "create specific table all events", %{conn: conn} do
      {:ok, subscription_params} = Subscriptions.parse_subscription_params(%{"schema" => "public", "table" => "test"})

      subscription_list = [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}]

      assert {:ok, [%Postgrex.Result{}]} =
               Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())

      %Postgrex.Result{rows: [[1]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end

    test "publication does not exist", %{conn: conn} do
      {:ok, subscription_params} = Subscriptions.parse_subscription_params(%{"schema" => "public", "table" => "test"})

      subscription_list = [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}]

      Postgrex.query!(conn, "drop publication if exists supabase_realtime_test", [])

      assert {:error,
              {:subscription_insert_failed,
               "Unable to subscribe to changes with given parameters. Please check Realtime is enabled for the given connect parameters: [event: *, schema: public, table: test, filters: []]"}} =
               Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())

      %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end

    test "table does not exist", %{conn: conn} do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{"schema" => "public", "table" => "doesnotexist"})

      subscription_list = [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}]

      assert {:error,
              {:subscription_insert_failed,
               "Unable to subscribe to changes with given parameters. Please check Realtime is enabled for the given connect parameters: [event: *, schema: public, table: doesnotexist, filters: []]"}} =
               Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())

      %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end

    test "column does not exist", %{conn: conn} do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{
          "schema" => "public",
          "table" => "test",
          "filter" => "subject=eq.hey"
        })

      subscription_list = [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}]

      assert {:error,
              {:subscription_insert_failed,
               "Unable to subscribe to changes with given parameters. An exception happened so please check your connect parameters: [event: *, schema: public, table: test, filters: [{\"subject\", \"eq\", \"hey\"}]]. Exception: ERROR P0001 (raise_exception) invalid column for filter subject"}} =
               Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())

      %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end

    test "column type is wrong", %{conn: conn} do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{
          "schema" => "public",
          "table" => "test",
          "filter" => "id=eq.hey"
        })

      subscription_list = [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}]

      assert {:error,
              {:subscription_insert_failed,
               "Unable to subscribe to changes with given parameters. An exception happened so please check your connect parameters: [event: *, schema: public, table: test, filters: [{\"id\", \"eq\", \"hey\"}]]. Exception: ERROR 22P02 (invalid_text_representation) invalid input syntax for type integer: \"hey\""}} =
               Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())

      %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end

    test "connection error" do
      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{"schema" => "public", "table" => "test"})

      subscription_list = [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}]
      conn = spawn(fn -> :ok end)

      assert {:error, {:exit, _}} =
               Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())
    end

    test "timeout", %{conn: conn} do
      {:ok, subscription_params} = Subscriptions.parse_subscription_params(%{"schema" => "public", "table" => "test"})

      Task.start(fn -> Postgrex.query!(conn, "SELECT pg_sleep(20)", []) end)

      subscription_list = [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}]

      assert {:error, %DBConnection.ConnectionError{reason: :queue_timeout}} =
               Subscriptions.create(conn, "supabase_realtime_test", subscription_list, self(), self())
    end

    test "invalid table" do
      {:error,
       "No subscription params provided. Please provide at least a `schema` or `table` to subscribe to: %{\"schema\" => \"public\", \"table\" => %{\"actually a\" => \"map\"}}"} =
        Subscriptions.parse_subscription_params(%{"schema" => "public", "table" => %{"actually a" => "map"}})
    end

    test "invalid schema" do
      {:error,
       "No subscription params provided. Please provide at least a `schema` or `table` to subscribe to: %{\"schema\" => %{\"actually a\" => \"map\"}, \"table\" => \"images\"}"} =
        Subscriptions.parse_subscription_params(%{"table" => "images", "schema" => %{"actually a" => "map"}})
    end

    test "invalid filter" do
      {:error,
       "No subscription params provided. Please provide at least a `schema` or `table` to subscribe to: %{\"filter\" => ~c\"{\", \"schema\" => \"public\", \"table\" => \"images\"}"} =
        Subscriptions.parse_subscription_params(%{"schema" => "public", "table" => "images", "filter" => [123]})
    end
  end

  describe "delete_all/1" do
    test "delete_all", %{conn: conn} do
      create_subscriptions(conn, 10)
      assert {:ok, %Postgrex.Result{}} = Subscriptions.delete_all(conn)
      assert %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end
  end

  describe "delete/2" do
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

  describe "maybe_delete_all/1" do
    test "maybe_delete_all", %{conn: conn} do
      Subscriptions.delete_all(conn)
      create_subscriptions(conn, 10)

      assert {:ok, %Postgrex.Result{}} = Subscriptions.maybe_delete_all(conn)
      assert %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end
  end

  describe "fetch_publication_tables/2" do
    test "fetch_publication_tables", %{conn: conn} do
      tables = Subscriptions.fetch_publication_tables(conn, "supabase_realtime_test")
      assert tables[{"*"}] != nil
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
            subscription_params: {"*", "public", "*", []}
          }
          | acc
        ]
      end)

    Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())
  end
end
