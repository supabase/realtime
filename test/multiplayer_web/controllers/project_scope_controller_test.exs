defmodule MultiplayerWeb.ProjectScopeControllerTest do
  use MultiplayerWeb.ConnCase

  alias Multiplayer.Api
  alias Multiplayer.Api.ProjectScope

  @create_attrs %{
    host: "some host"
  }
  @update_attrs %{
    host: "some updated host"
  }
  @invalid_attrs %{host: nil}

  def fixture(:project_scope) do
    {:ok, project_scope} = Api.create_project_scope(@create_attrs)
    project_scope
  end

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "index" do
    test "lists all project_scopes", %{conn: conn} do
      conn = get(conn, Routes.project_scope_path(conn, :index))
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "create project_scope" do
    test "renders project_scope when data is valid", %{conn: conn} do
      conn = post(conn, Routes.project_scope_path(conn, :create), project_scope: @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, Routes.project_scope_path(conn, :show, id))

      assert %{
               "id" => id,
               "host" => "some host"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, Routes.project_scope_path(conn, :create), project_scope: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "update project_scope" do
    setup [:create_project_scope]

    test "renders project_scope when data is valid", %{conn: conn, project_scope: %ProjectScope{id: id} = project_scope} do
      conn = put(conn, Routes.project_scope_path(conn, :update, project_scope), project_scope: @update_attrs)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, Routes.project_scope_path(conn, :show, id))

      assert %{
               "id" => id,
               "host" => "some updated host"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn, project_scope: project_scope} do
      conn = put(conn, Routes.project_scope_path(conn, :update, project_scope), project_scope: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "delete project_scope" do
    setup [:create_project_scope]

    test "deletes chosen project_scope", %{conn: conn, project_scope: project_scope} do
      conn = delete(conn, Routes.project_scope_path(conn, :delete, project_scope))
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, Routes.project_scope_path(conn, :show, project_scope))
      end
    end
  end

  defp create_project_scope(_) do
    project_scope = fixture(:project_scope)
    %{project_scope: project_scope}
  end
end
