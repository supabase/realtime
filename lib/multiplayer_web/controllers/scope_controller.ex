defmodule MultiplayerWeb.ScopeController do
  use MultiplayerWeb, :controller

  alias Multiplayer.Api
  alias Multiplayer.Api.Scope

  action_fallback MultiplayerWeb.FallbackController

  def index(conn, _params) do
    scopes = Api.list_scopes()
    render(conn, "index.json", scopes: scopes)
  end

  def create(conn, %{"scope" => scope_params}) do
    with {:ok, %Scope{} = scope} <- Api.create_scope(scope_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", Routes.scope_path(conn, :show, scope))
      |> render("show.json", scope: scope)
    end
  end

  def show(conn, %{"id" => id}) do
    scope = Api.get_scope!(id)
    render(conn, "show.json", scope: scope)
  end

  def update(conn, %{"id" => id, "scope" => scope_params}) do
    scope = Api.get_scope!(id)

    with {:ok, %Scope{} = scope} <- Api.update_scope(scope, scope_params) do
      render(conn, "show.json", scope: scope)
    end
  end

  def delete(conn, %{"id" => id}) do
    scope = Api.get_scope!(id)

    with {:ok, %Scope{}} <- Api.delete_scope(scope) do
      send_resp(conn, :no_content, "")
    end
  end
end
