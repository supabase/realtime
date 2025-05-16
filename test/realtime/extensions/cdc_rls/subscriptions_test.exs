defmodule Realtime.Extensionsubscriptions.CdcRlsSubscriptionsTest do
  use RealtimeWeb.ChannelCase, async: true
  doctest Extensions.PostgresCdcRls.Subscriptions

  alias Extensions.PostgresCdcRls.Subscriptions
  alias Realtime.Database
  alias Realtime.Tenants

  setup do
    tenant = Tenants.get_tenant_by_external_id("dev_tenant")

    {:ok, conn} =
      tenant
      |> Database.from_tenant("realtime_rls")
      |> Map.from_struct()
      |> Keyword.new()
      |> Postgrex.start_link()

    %{conn: conn}
  end

  test "create", %{conn: conn} do
    Subscriptions.delete_all(conn)

    assert %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])

    params_list = [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), params: %{"event" => "*", "schema" => "public"}}]

    assert {:ok, [%Postgrex.Result{}]} =
             Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())

    Process.sleep(500)

    params_list = [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), params: %{"schema" => "public", "table" => "test"}}]

    assert {:ok, [%Postgrex.Result{}]} =
             Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())

    Process.sleep(500)

    params_list = [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), params: %{}}]

    assert {:error,
            "No subscription params provided. Please provide at least a `schema` or `table` to subscribe to: %{}"} =
             Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())

    Process.sleep(500)

    params_list = [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), params: %{"user_token" => "potato"}}]

    assert {:error,
            "No subscription params provided. Please provide at least a `schema` or `table` to subscribe to: <redacted>"} =
             Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())

    Process.sleep(500)

    params_list = [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), params: %{"auth_token" => "potato"}}]

    assert {:error,
            "No subscription params provided. Please provide at least a `schema` or `table` to subscribe to: <redacted>"} =
             Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())

    Process.sleep(500)

    %Postgrex.Result{rows: [[num]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    assert num != 0
  end

  test "delete_all", %{conn: conn} do
    create_subscriptions(conn, 10)
    assert {:ok, %Postgrex.Result{}} = Subscriptions.delete_all(conn)
    assert %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
  end

  test "delete", %{conn: conn} do
    Subscriptions.delete_all(conn)
    id = UUID.uuid1()
    bin_id = UUID.string_to_binary!(id)

    params_list = [%{id: id, claims: %{"role" => "anon"}, params: %{"event" => "*"}}]
    Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())
    Process.sleep(500)

    assert {:ok, %Postgrex.Result{}} = Subscriptions.delete(conn, bin_id)
    assert %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
  end

  test "delete_multi", %{conn: conn} do
    Subscriptions.delete_all(conn)
    id1 = UUID.uuid1()
    id2 = UUID.uuid1()

    bin_id2 = UUID.string_to_binary!(id2)
    bin_id1 = UUID.string_to_binary!(id1)

    params_list = [
      %{claims: %{"role" => "anon"}, id: id1, params: %{"event" => "*"}},
      %{claims: %{"role" => "anon"}, id: id2, params: %{"event" => "*"}}
    ]

    Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())
    Process.sleep(500)

    assert {:ok, %Postgrex.Result{}} = Subscriptions.delete_multi(conn, [bin_id1, bin_id2])
    assert %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
  end

  test "maybe_delete_all", %{conn: conn} do
    Subscriptions.delete_all(conn)
    create_subscriptions(conn, 10)

    assert {:ok, %Postgrex.Result{}} = Subscriptions.maybe_delete_all(conn)
    assert %Postgrex.Result{rows: [[0]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
  end

  test "fetch_publication_tables", %{conn: conn} do
    tables = Subscriptions.fetch_publication_tables(conn, "supabase_realtime_test")
    assert tables[{"*"}] != nil
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
            params: %{"event" => "*", "schema" => "public"}
          }
          | acc
        ]
      end)

    Subscriptions.create(conn, "supabase_realtime_test", params_list, self(), self())
    Process.sleep(500)
  end
end
