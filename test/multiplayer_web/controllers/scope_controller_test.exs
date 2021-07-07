defmodule MultiplayerWeb.ScopeControllerTest do
  use MultiplayerWeb.ConnCase

  alias Multiplayer.Api
  alias Multiplayer.Api.Scope

  @create_attrs %{
    host: "some host"
  }
  @update_attrs %{
    host: "some updated host"
  }
  @invalid_attrs %{host: nil}

  def fixture(:scope) do
    {:ok, project} = Api.create_project(%{name: "project1", secret: "secret"})
    attrs = Map.put(@create_attrs, :project_id, project.id)
    {:ok, scope} = Api.create_scope(attrs)
    scope
  end

  setup %{conn: conn} do
    {:ok, project} = Api.create_project(%{name: "project1", secret: "secret"})
    {:ok,
      conn: put_req_header(conn, "accept", "application/json"),
      project: project
    }
  end

  describe "index" do
    test "lists all scopes", %{conn: conn} do
      conn = get(conn, Routes.scope_path(conn, :index))
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "create scope" do
    test "renders scope when data is valid", %{conn: conn, project: project} do
      attrs = Map.put(@create_attrs, :project_id, project.id)
      conn = post(conn, Routes.scope_path(conn, :create), scope: attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, Routes.scope_path(conn, :show, id))
      project_id = project.id
      assert %{
               "id" => id,
               "host" => "some host",
               "project_id" => project_id
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn, project: project} do
      conn = post(conn, Routes.scope_path(conn, :create), scope: @create_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "update scope" do
    setup [:create_scope]

    test "renders scope when data is valid", %{conn: conn, scope: %Scope{id: id} = scope} do
      conn = put(conn, Routes.scope_path(conn, :update, scope), scope: @update_attrs)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, Routes.scope_path(conn, :show, id))

      assert %{
               "id" => id,
               "host" => "some updated host"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn, scope: scope} do
      conn = put(conn, Routes.scope_path(conn, :update, scope), scope: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "delete scope" do
    setup [:create_scope]

    test "deletes chosen scope", %{conn: conn, scope: scope} do
      conn = delete(conn, Routes.scope_path(conn, :delete, scope))
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, Routes.scope_path(conn, :show, scope))
      end
    end
  end

  defp create_scope(_) do
    scope = fixture(:scope)
    %{scope: scope}
  end
end
