defmodule MultiplayerWeb.ProjectView do
  use MultiplayerWeb, :view
  alias MultiplayerWeb.ProjectView

  def render("index.json", %{projects: projects}) do
    %{data: render_many(projects, ProjectView, "project.json")}
  end

  def render("show.json", %{project: project}) do
    %{data: render_one(project, ProjectView, "project.json")}
  end

  def render("project.json", %{project: project}) do
    %{id: project.id,
      name: project.name,
      external_id: project.external_id,
      jwt_secret: project.jwt_secret}
  end
end
