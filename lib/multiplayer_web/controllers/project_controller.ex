defmodule MultiplayerWeb.ProjectController do
  use MultiplayerWeb, :controller
  use PhoenixSwagger
  alias Multiplayer.Api
  alias Multiplayer.Api.Project

  action_fallback MultiplayerWeb.FallbackController

  swagger_path :index do
    PhoenixSwagger.Path.get "/api/projects"
    tag "Projects"
    response 200, "Success", :ProjectsResponse
  end

  def index(conn, _params) do
    projects = Api.list_projects()
    render(conn, "index.json", projects: projects)
  end

  swagger_path :create do
    PhoenixSwagger.Path.post "/api/projects"
    tag "Projects"
    parameters do
      project(:body, Schema.ref(:ProjectReq), "", required: true)
    end
    response 200, "Success", :ProjectResponse
  end

  def create(conn, %{"project" => project_params}) do
    with {:ok, %Project{} = project} <- Api.create_project(project_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", Routes.project_path(conn, :show, project))
      |> render("show.json", project: project)
    end
  end

  swagger_path :show do
    PhoenixSwagger.Path.get "/api/projects/{id}"
    tag "Projects"
    parameter :id, :path, :string, "", required: true, example: "72ac258c-8dcd-4f0d-992f-9b6bab5e6d19"
    response 200, "Success", :ProjectResponse
  end

  def show(conn, %{"id" => id}) do
    project = Api.get_project!(id)
    render(conn, "show.json", project: project)
  end

  swagger_path :update do
    PhoenixSwagger.Path.put "/api/projects/{id}"
    tag "Projects"
    parameters do
      id(:path, :string, "", required: true, example: "72ac258c-8dcd-4f0d-992f-9b6bab5e6d19")
      project(:body, Schema.ref(:ProjectReq), "", required: true)
    end
    response 200, "Success", :ProjectResponse
  end

  def update(conn, %{"id" => id, "project" => project_params}) do
    project = Api.get_project!(id)

    with {:ok, %Project{} = project} <- Api.update_project(project, project_params) do
      render(conn, "show.json", project: project)
    end
  end

  swagger_path :delete do
    PhoenixSwagger.Path.delete "/api/projects/{id}"
    tag "Projects"
    description "Delete a project by ID"
    parameter :id, :path, :string, "Project ID", required: true, example: "123e4567-e89b-12d3-a456-426655440000"
    response 200, "No Content - Deleted Successfully"
  end

  def delete(conn, %{"id" => id}) do
    project = Api.get_project!(id)

    with {:ok, %Project{}} <- Api.delete_project(project) do
      send_resp(conn, :no_content, "")
    end
  end

  def swagger_definitions do
    %{
      Project: swagger_schema do
        title "Project"
        properties do
          id          :string, "", required: false,  example: "72ac258c-8dcd-4f0d-992f-9b6bab5e6d19"
          name        :string, "", required: false,  example: "project1"
          jwt_secret  :string, "", required: false,  example: "big_secret"
          external_id :string, "", required: false,  example: "okumviwlylkmpkoicbrc"
        end
      end,
      ProjectReq: swagger_schema do
        title "ProjectReq"
        properties do
          name        :string, "", required: false, example: "project1"
          jwt_secret  :string, "", required: true,  example: "big_secret"
          external_id :string, "", required: true,  example: "okumviwlylkmpkoicbrc"
        end
      end,
      Projects: swagger_schema do
        title "Projects"
        type :array
        items Schema.ref(:Project)
      end,
      ProjectsResponse: swagger_schema do
        title "ProjectsResponse"
        property(:data, Schema.ref(:Projects), "")
      end,
      ProjectResponse: swagger_schema do
        title "ProjectResponse"
        property(:data, Schema.ref(:Project), "")
      end
    }
  end

end
