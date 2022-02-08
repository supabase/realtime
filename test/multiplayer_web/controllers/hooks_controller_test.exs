defmodule MultiplayerWeb.HooksControllerTest do
  use MultiplayerWeb.ConnCase

  alias Multiplayer.Api
  alias Multiplayer.Api.Hooks

  @create_attrs %{
    event: "some event",
    type: "some type",
    url: "some url"
  }
  @update_attrs %{
    event: "some updated event",
    type: "some updated type",
    url: "some updated url"
  }
  @invalid_attrs %{event: nil, type: nil, url: nil}

  def fixture(:hooks) do
    {:ok, hooks} = Api.create_hooks(@create_attrs)
    hooks
  end

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "index" do
    test "lists all hooks", %{conn: conn} do
      conn = get(conn, Routes.hooks_path(conn, :index))
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "create hooks" do
    test "renders hooks when data is valid", %{conn: conn} do
      conn = post(conn, Routes.hooks_path(conn, :create), hooks: @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, Routes.hooks_path(conn, :show, id))

      assert %{
               "id" => id,
               "event" => "some event",
               "type" => "some type",
               "url" => "some url"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, Routes.hooks_path(conn, :create), hooks: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "update hooks" do
    setup [:create_hooks]

    test "renders hooks when data is valid", %{conn: conn, hooks: %Hooks{id: id} = hooks} do
      conn = put(conn, Routes.hooks_path(conn, :update, hooks), hooks: @update_attrs)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, Routes.hooks_path(conn, :show, id))

      assert %{
               "id" => id,
               "event" => "some updated event",
               "type" => "some updated type",
               "url" => "some updated url"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn, hooks: hooks} do
      conn = put(conn, Routes.hooks_path(conn, :update, hooks), hooks: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "delete hooks" do
    setup [:create_hooks]

    test "deletes chosen hooks", %{conn: conn, hooks: hooks} do
      conn = delete(conn, Routes.hooks_path(conn, :delete, hooks))
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, Routes.hooks_path(conn, :show, hooks))
      end
    end
  end

  defp create_hooks(_) do
    hooks = fixture(:hooks)
    %{hooks: hooks}
  end
end
