defmodule MultiplayerWeb.PageController do
  use MultiplayerWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end
end
