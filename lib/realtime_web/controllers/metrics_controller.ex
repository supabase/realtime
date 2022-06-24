defmodule RealtimeWeb.MetricsController do
  use RealtimeWeb, :controller

  def index(conn, %{"region" => region, "num" => num}) do
    num = String.to_integer(num)

    :syn.members(Extensions.Postgres.RegionNodes, region)
    |> Enum.at(num)
    |> case do
      nil ->
        send_resp(conn, 404, "Not found")

      {_, [node: node]} ->
        case :rpc.call(node, Realtime.PromEx, :get_metrics, []) do
          {:badrpc, reason} ->
            send_resp(conn, 503, inspect(reason))

          metrics ->
            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(200, metrics)
        end
    end
  end
end
