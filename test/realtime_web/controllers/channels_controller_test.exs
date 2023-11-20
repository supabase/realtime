defmodule RealtimeWeb.ChannelsControllerTest do
  use RealtimeWeb.ConnCase, async: false

  import Mock

  alias Realtime.GenCounter
  alias Realtime.Tenants

  @cdc "postgres_cdc_rls"
  @token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE1MTYyMzkwMjIsInJvbGUiOiJmb28iLCJleHAiOiJiYXIifQ.Ret2CevUozCsPhpgW2FMeFL7RooLgoOvfQzNpLBj5ak"

  setup_with_mocks [
                     {GenCounter, [], new: fn _ -> :ok end},
                     {GenCounter, [], add: fn _ -> :ok end},
                     {GenCounter, [], put: fn _, _ -> :ok end},
                     {GenCounter, [], get: fn _ -> {:ok, 0} end}
                   ],
                   %{conn: conn} do
    start_supervised(RealtimeWeb.Joken.CurrentTime.Mock)
    tenant = tenant_fixture()
    settings = Realtime.PostgresCdc.filter_settings(@cdc, tenant.extensions)
    settings = Map.put(settings, "id", tenant.external_id)
    settings = Map.put(settings, "db_socket_opts", [:inet])

    start_supervised!({Tenants.Migrations, settings})
    {:ok, db_conn} = Tenants.Connect.lookup_or_start_connection(tenant.external_id)
    truncate_table(db_conn, "realtime.channels")

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{@token}")
      |> then(&%{&1 | host: "#{tenant.external_id}.supabase.com"})

    {:ok, conn: conn, tenant: tenant}
  end

  describe "index" do
    test "lists tenant channels", %{conn: conn, tenant: tenant} do
      expected =
        Stream.repeatedly(fn -> channel_fixture(tenant) end)
        |> Enum.take(10)
        |> Jason.encode!()
        |> Jason.decode!()

      conn = get(conn, ~p"/api/channels")
      res = json_response(conn, 200)

      res = Enum.sort_by(res, fn %{"id" => id} -> id end)
      expected = Enum.sort_by(expected, fn %{"id" => id} -> id end)
      assert res == expected
    end
  end

  describe "show" do
    test "lists tenant channels", %{conn: conn, tenant: tenant} do
      [channel | _] =
        Stream.repeatedly(fn -> channel_fixture(tenant) end)
        |> Enum.take(10)

      expected = channel |> Jason.encode!() |> Jason.decode!()

      conn = get(conn, ~p"/api/channels/#{channel.id}")
      res = json_response(conn, 200)
      assert res == expected
    end

    test "returns not found if id doesn't exist", %{conn: conn} do
      conn = get(conn, ~p"/api/channels/0")
      assert json_response(conn, 404) == %{"message" => "Not found"}
    end
  end

  describe "create" do
    test "creates a channel", %{conn: conn} do
      name = random_string()
      conn = post(conn, ~p"/api/channels", %{name: name})
      res = json_response(conn, 201)
      assert name == res["name"]
    end

    test "422 if params are invalid", %{conn: conn} do
      conn = post(conn, ~p"/api/channels", %{})
      assert json_response(conn, 422) == %{"errors" => %{"name" => ["can't be blank"]}}
    end
  end

  describe "delete" do
    test "deletes a channel", %{conn: conn, tenant: tenant} do
      channel = channel_fixture(tenant)
      conn = delete(conn, ~p"/api/channels/#{channel.id}")
      assert conn.status == 202
    end

    test "returns not found if id doesn't exist", %{conn: conn} do
      conn = delete(conn, ~p"/api/channels/0")
      assert conn.status == 404
    end
  end
end
