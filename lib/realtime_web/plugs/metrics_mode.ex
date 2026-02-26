defmodule RealtimeWeb.Plugs.MetricsMode do
  @moduledoc """
  Plug to dispatch metrics requests to the appropriate controller based on the metrics mode.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if Application.get_env(:realtime, :metrics_separation_enabled, false), do: conn, else: dispatch_legacy(conn)
  end

  defp dispatch_legacy(%{path_info: ["tenant-metrics" | _]} = conn) do
    conn |> send_resp(404, "") |> halt()
  end

  defp dispatch_legacy(conn) do
    action = if conn.path_params["region"], do: :region, else: :index

    conn
    |> put_private(:phoenix_controller, RealtimeWeb.LegacyMetricsController)
    |> put_private(:phoenix_action, action)
    |> RealtimeWeb.LegacyMetricsController.call(action)
    |> halt()
  end
end
