defmodule RealtimeWeb.PageController do
  use RealtimeWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end
end
