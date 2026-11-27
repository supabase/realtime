defmodule RealtimeWeb.PageController do
  use RealtimeWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end

  def redirect_to_root(conn, _params) do
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    redirect(conn, to: "/" <> query)
  end

  def healthcheck(conn, _params) do
    conn
    |> put_status(:ok)
    |> text("ok")
  end

  def ready(conn, _params) do
    case Realtime.Readiness.check() do
      :ok ->
        conn |> put_status(:ok) |> text("ok")

      {:error, :shutdown_in_progress} ->
        conn |> put_status(:service_unavailable) |> text("shutting down")

      # What it waits for is in the logs (Realtime.Readiness), not in the response.
      {:error, {:waiting_for_nodes, _shortfalls}} ->
        conn |> put_status(:service_unavailable) |> text("not ready")
    end
  end
end
