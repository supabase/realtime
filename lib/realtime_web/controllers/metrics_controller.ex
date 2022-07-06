defmodule RealtimeWeb.MetricsController do
  use RealtimeWeb, :controller
  require Logger
  alias Realtime.PromEx

  def index(conn, _) do
    cluster_metrics =
      Node.list()
      |> Task.async_stream(
        fn node ->
          {node, :rpc.call(node, PromEx, :get_metrics, [], 5_000)}
        end,
        timeout: :infinity
      )
      |> Enum.reduce(PromEx.get_metrics(), fn {_, {node, response}}, acc ->
        case response do
          {:badrpc, reason} ->
            Logger.error(
              "Cannot fetch metrics from the node #{inspect(node)} because #{inspect(reason)}"
            )

            acc

          metrics ->
            acc <> metrics
        end
      end)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, cluster_metrics)
  end

  def show(conn, %{"region" => region, "num" => num}) do
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
