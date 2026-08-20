defmodule RealtimeWeb.PageController do
  use RealtimeWeb, :controller

  alias Realtime.SignalHandler

  def index(conn, _params) do
    render(conn, "index.html")
  end

  def redirect_to_root(conn, _params) do
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    redirect(conn, to: "/" <> query)
  end

  def healthcheck(conn, _params) do
    case SignalHandler.shutdown_in_progress?() do
      :ok -> conn |> put_status(:ok) |> text("ok")
      {:error, :shutdown_in_progress} -> conn |> put_status(:service_unavailable) |> text("shutting down")
    end
  end
end
