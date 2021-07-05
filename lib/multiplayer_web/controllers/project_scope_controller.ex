defmodule MultiplayerWeb.ProjectScopeController do
  use MultiplayerWeb, :controller

  alias Multiplayer.Api
  alias Multiplayer.Api.ProjectScope

  action_fallback MultiplayerWeb.FallbackController

  def index(conn, _params) do
    project_scopes = Api.list_project_scopes()
    render(conn, "index.json", project_scopes: project_scopes)
  end

  def create(conn, %{"project_scope" => project_scope_params}) do
    with {:ok, %ProjectScope{} = project_scope} <- Api.create_project_scope(project_scope_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", Routes.project_scope_path(conn, :show, project_scope))
      |> render("show.json", project_scope: project_scope)
    end
  end

  def show(conn, %{"id" => id}) do
    project_scope = Api.get_project_scope!(id)
    render(conn, "show.json", project_scope: project_scope)
  end

  def update(conn, %{"id" => id, "project_scope" => project_scope_params}) do
    project_scope = Api.get_project_scope!(id)

    with {:ok, %ProjectScope{} = project_scope} <- Api.update_project_scope(project_scope, project_scope_params) do
      render(conn, "show.json", project_scope: project_scope)
    end
  end

  def delete(conn, %{"id" => id}) do
    project_scope = Api.get_project_scope!(id)

    with {:ok, %ProjectScope{}} <- Api.delete_project_scope(project_scope) do
      send_resp(conn, :no_content, "")
    end
  end
end
