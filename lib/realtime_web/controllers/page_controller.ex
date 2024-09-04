defmodule RealtimeWeb.PageController do
  use RealtimeWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end

  def healthcheck(conn, _params) do
    conn
    |> put_status(:ok)
    |> text("ok")
  end
end
