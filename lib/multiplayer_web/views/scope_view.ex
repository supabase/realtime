defmodule MultiplayerWeb.ScopeView do
  use MultiplayerWeb, :view
  alias MultiplayerWeb.ScopeView

  def render("index.json", %{scopes: scopes}) do
    %{data: render_many(scopes, ScopeView, "scope.json")}
  end

  def render("show.json", %{scope: scope}) do
    %{data: render_one(scope, ScopeView, "scope.json")}
  end

  def render("scope.json", %{scope: scope}) do
    %{
      id: scope.id,
      host: scope.host,
      tenant_id: scope.tenant_id
    }
  end
end
