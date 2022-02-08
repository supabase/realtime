defmodule MultiplayerWeb.HooksController do
  use MultiplayerWeb, :controller

  alias Multiplayer.Api
  alias Multiplayer.Api.Hooks

  action_fallback MultiplayerWeb.FallbackController

  def index(conn, _params) do
    hooks = Api.list_hooks()
    render(conn, "index.json", hooks: hooks)
  end

  def create(conn, %{"hooks" => hooks_params}) do
    with {:ok, %Hooks{} = hooks} <- Api.create_hooks(hooks_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", Routes.hooks_path(conn, :show, hooks))
      |> render("show.json", hooks: hooks)
    end
  end

  def show(conn, %{"id" => id}) do
    hooks = Api.get_hooks!(id)
    render(conn, "show.json", hooks: hooks)
  end

  def update(conn, %{"id" => id, "hooks" => hooks_params}) do
    hooks = Api.get_hooks!(id)

    with {:ok, %Hooks{} = hooks} <- Api.update_hooks(hooks, hooks_params) do
      render(conn, "show.json", hooks: hooks)
    end
  end

  def delete(conn, %{"id" => id}) do
    hooks = Api.get_hooks!(id)

    with {:ok, %Hooks{}} <- Api.delete_hooks(hooks) do
      send_resp(conn, :no_content, "")
    end
  end
end
