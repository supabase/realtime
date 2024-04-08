defmodule RealtimeWeb.ChannelsControllerTest do
  # async: false due to the fact that multiple operations against the database will use the same connection
  use RealtimeWeb.ConnCase, async: false

  alias Realtime.Tenants.Connect

  setup %{conn: conn} = context do
    start_supervised(Realtime.RateCounter.DynamicSupervisor)
    start_supervised(Realtime.GenCounter.DynamicSupervisor)
    start_supervised(RealtimeWeb.Joken.CurrentTime.Mock)
    tenant = tenant_fixture()

    secret =
      Realtime.Helpers.decrypt!(tenant.jwt_secret, Application.get_env(:realtime, :db_enc_key))

    {:ok, _} = start_supervised({Connect, tenant_id: tenant.external_id}, restart: :transient)
    {:ok, db_conn} = Connect.get_status(tenant.external_id)

    clean_table(db_conn, "realtime", "broadcasts")
    clean_table(db_conn, "realtime", "channels")

    create_rls_policies(
      db_conn,
      [
        :authenticated_all_channels_read,
        :authenticated_all_channels_insert,
        :authenticated_all_channels_update,
        :authenticated_all_channels_delete
      ],
      nil
    )

    claims = %{sub: random_string(), role: context.role, exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", secret)

    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{jwt}")
      |> then(&%{&1 | host: "#{tenant.external_id}.supabase.com"})

    {:ok, conn: conn, db_conn: db_conn, tenant: tenant}
  end

  describe "index" do
    @tag role: "authenticated"
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

    @tag role: "authenticated"
    test "returns empty list if unauthorized", %{conn: conn} do
      conn = get(conn, ~p"/api/channels")
      assert json_response(conn, 200) == []
    end
  end

  describe "show" do
    @tag role: "authenticated"
    test "lists tenant channels", %{conn: conn, tenant: tenant} do
      [channel | _] =
        Stream.repeatedly(fn -> channel_fixture(tenant) end)
        |> Enum.take(10)

      expected = channel |> Jason.encode!() |> Jason.decode!()

      conn = get(conn, ~p"/api/channels/#{channel.name}")
      res = json_response(conn, 200)
      assert res == expected
    end

    @tag role: "authenticated"
    test "returns not found if id doesn't exist", %{conn: conn, tenant: tenant} do
      Stream.repeatedly(fn -> channel_fixture(tenant) end)
      |> Enum.take(10)

      conn = get(conn, ~p"/api/channels/0")
      assert json_response(conn, 404) == %{"message" => "Not found"}
    end

    @tag role: "anon"
    test "returns 404 if unauthorized", %{conn: conn} do
      conn = get(conn, ~p"/api/channels/0")
      assert json_response(conn, 404) == %{"message" => "Not found"}
    end
  end

  describe "create" do
    @tag role: "authenticated"
    test "creates a channel", %{conn: conn} do
      name = random_string()
      conn = post(conn, ~p"/api/channels", %{"name" => name})
      res = json_response(conn, 201)
      assert name == res["name"]
    end

    @tag role: "authenticated"
    test "422 if params are invalid", %{conn: conn, tenant: tenant} do
      name = random_string()
      channel_fixture(tenant, %{name: name})
      conn = post(conn, ~p"/api/channels", %{"name" => name})
      assert json_response(conn, 422) == %{"errors" => %{"name" => ["has already been taken"]}}
    end

    @tag role: "anon"
    test "returns 401 if unauthorized", %{conn: conn} do
      conn = post(conn, ~p"/api/channels", %{name: random_string()})
      assert json_response(conn, 401) == %{"message" => "Unauthorized"}
    end
  end

  describe "delete" do
    @tag role: "authenticated"
    test "deletes a channel", %{conn: conn, tenant: tenant} do
      channel = channel_fixture(tenant)
      conn = delete(conn, ~p"/api/channels/#{channel.name}")
      assert conn.status == 202
    end

    @tag role: "authenticated"
    test "returns 404 if id doesn't exist", %{conn: conn} do
      conn = delete(conn, ~p"/api/channels/0")
      assert conn.status == 404
    end

    @tag role: "anon"
    test "returns 404 if unauthorized", %{conn: conn, tenant: tenant} do
      channel = channel_fixture(tenant)
      conn = delete(conn, ~p"/api/channels/#{channel.name}")
      assert json_response(conn, 404) == %{"message" => "Not found"}
    end
  end

  describe "update" do
    @tag role: "authenticated"
    test "updates a channel", %{conn: conn, tenant: tenant} do
      channel = channel_fixture(tenant)
      name = random_string()
      conn = put(conn, ~p"/api/channels/#{channel.name}", %{name: name})
      res = json_response(conn, 202)
      assert name == res["name"]

      channel = channel_fixture(tenant)
      name = random_string()
      conn = patch(conn, ~p"/api/channels/#{channel.name}", %{name: name})
      res = json_response(conn, 202)
      assert name == res["name"]
    end

    @tag role: "authenticated"
    test "422 if params are invalid", %{conn: conn, tenant: tenant} do
      channel = channel_fixture(tenant)
      conn = put(conn, ~p"/api/channels/#{channel.name}", %{"name" => 1})
      assert json_response(conn, 422) == %{"errors" => %{"name" => ["is invalid"]}}
      conn = patch(conn, ~p"/api/channels/#{channel.name}", %{"name" => 1})
      assert json_response(conn, 422) == %{"errors" => %{"name" => ["is invalid"]}}
    end

    @tag role: "anon"
    test "returns 404 if unauthorized", %{conn: conn, tenant: tenant} do
      channel = channel_fixture(tenant)
      conn = put(conn, ~p"/api/channels/#{channel.name}", %{"name" => "new_name"})
      assert json_response(conn, 404) == %{"message" => "Not found"}
    end
  end
end
