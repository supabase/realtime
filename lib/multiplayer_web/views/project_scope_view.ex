defmodule MultiplayerWeb.ProjectScopeView do
  use MultiplayerWeb, :view
  alias MultiplayerWeb.ProjectScopeView

  def render("index.json", %{project_scopes: project_scopes}) do
    %{data: render_many(project_scopes, ProjectScopeView, "project_scope.json")}
  end

  def render("show.json", %{project_scope: project_scope}) do
    %{data: render_one(project_scope, ProjectScopeView, "project_scope.json")}
  end

  def render("project_scope.json", %{project_scope: project_scope}) do
    %{id: project_scope.id,
      host: project_scope.host}
  end
end
