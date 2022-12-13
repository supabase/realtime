defmodule Realtime.Extensions.CdcRlsSubscriptionsTest do
  use RealtimeWeb.ChannelCase
  doctest Extensions.PostgresCdcRls.Subscriptions

  alias Extensions.PostgresCdcRls.Subscriptions, as: S
  alias Postgrex, as: P

  setup %{} do
    repo = Application.get_env(:realtime, Realtime.Repo)

    {:ok, conn} =
      Postgrex.start_link(
        hostname: repo[:hostname],
        database: repo[:database],
        password: repo[:password],
        username: repo[:username]
      )

    %{conn: conn}
  end

  test "create", %{conn: conn} do
    S.delete_all(conn)

    assert %Postgrex.Result{rows: [[0]]} =
             P.query!(conn, "select count(*) from realtime.subscription", [])

    params_list = [
      %{
        claims: %{
          "role" => "anon"
        },
        id: UUID.uuid1(),
        params: %{"event" => "*", "schema" => "public"}
      }
    ]

    assert {:ok, [%Postgrex.Result{}]} = S.create(conn, "supabase_realtime_test", params_list)

    params_list = [
      %{
        claims: %{
          "role" => "anon"
        },
        id: UUID.uuid1(),
        params: %{"schema" => "public", "table" => "tenants"}
      }
    ]

    assert {:ok, [%Postgrex.Result{}]} = S.create(conn, "supabase_realtime_test", params_list)

    params_list = [
      %{
        claims: %{
          "role" => "anon"
        },
        id: UUID.uuid1(),
        params: %{}
      }
    ]

    assert {:error,
            "No subscription params provided. Please provide at least a `schema` or `table` to subscribe to."} =
             S.create(conn, "supabase_realtime_test", params_list)

    %Postgrex.Result{rows: [[num]]} =
      P.query!(conn, "select count(*) from realtime.subscription", [])

    assert num != 0
  end

  test "delete_all", %{conn: conn} do
    create_subscriptions(conn, 10)
    assert {:ok, %P.Result{}} = S.delete_all(conn)

    assert %Postgrex.Result{rows: [[0]]} =
             P.query!(conn, "select count(*) from realtime.subscription", [])
  end

  test "delete", %{conn: conn} do
    S.delete_all(conn)
    id = UUID.uuid1()
    bin_id = id |> UUID.string_to_binary!()

    params_list = [
      %{
        claims: %{
          "role" => "anon"
        },
        id: id,
        params: %{"event" => "*"}
      }
    ]

    S.create(conn, "supabase_realtime_test", params_list)

    assert {:ok, %P.Result{}} = S.delete(conn, bin_id)

    assert %Postgrex.Result{rows: [[0]]} =
             P.query!(conn, "select count(*) from realtime.subscription", [])
  end

  test "delete_multi", %{conn: conn} do
    S.delete_all(conn)
    id1 = UUID.uuid1()
    bin_id1 = id1 |> UUID.string_to_binary!()

    id2 = UUID.uuid1()
    bin_id2 = id2 |> UUID.string_to_binary!()

    params_list = [
      %{
        claims: %{
          "role" => "anon"
        },
        id: id1,
        params: %{"event" => "*"}
      },
      %{
        claims: %{
          "role" => "anon"
        },
        id: id2,
        params: %{"event" => "*"}
      }
    ]

    S.create(conn, "supabase_realtime_test", params_list)

    assert {:ok, %P.Result{}} = S.delete_multi(conn, [bin_id1, bin_id2])

    assert %Postgrex.Result{rows: [[0]]} =
             P.query!(conn, "select count(*) from realtime.subscription", [])
  end

  test "maybe_delete_all", %{conn: conn} do
    S.delete_all(conn)
    create_subscriptions(conn, 10)
    assert {:ok, %P.Result{}} = S.maybe_delete_all(conn)

    assert %Postgrex.Result{rows: [[0]]} =
             P.query!(conn, "select count(*) from realtime.subscription", [])
  end

  test "fetch_publication_tables", %{conn: conn} do
    tables = S.fetch_publication_tables(conn, "supabase_realtime_test")
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
              "ref" => "localhost",
              "role" => "anon"
            },
            id: UUID.uuid1(),
            params: %{"event" => "*", "schema" => "public"}
          }
          | acc
        ]
      end)

    S.create(conn, "supabase_realtime_test", params_list)
  end
end
