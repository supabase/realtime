defmodule Realtime.MetricsPusher do
  @moduledoc """
  GenServer that periodically pushes Prometheus metrics to an endpoint.

  Only starts if `url` is configured.
  Pushes metrics every 30 seconds (configurable) to the configured URL endpoint.
  """

  use GenServer
  require Logger

  defstruct [:push_ref, :interval, :req_options, :auth]

  @spec start_link(keyword()) :: {:ok, pid()} | :ignore
  def start_link(opts) do
    url = opts[:url] || Application.get_env(:realtime, :metrics_pusher_url)

    if is_binary(url) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      Logger.warning("MetricsPusher not started: url must be configured")

      :ignore
    end
  end

  @impl true
  def init(opts) do
    url = opts[:url] || Application.get_env(:realtime, :metrics_pusher_url)
    user = opts[:user] || Application.get_env(:realtime, :metrics_pusher_user, "realtime")
    auth = opts[:auth] || Application.get_env(:realtime, :metrics_pusher_auth)

    interval =
      Keyword.get(
        opts,
        :interval,
        Application.get_env(:realtime, :metrics_pusher_interval_ms, :timer.seconds(30))
      )

    timeout =
      Keyword.get(
        opts,
        :timeout,
        Application.get_env(:realtime, :metrics_pusher_timeout_ms, :timer.seconds(15))
      )

    Logger.info("Starting MetricsPusher (url: #{url}, interval: #{interval}ms)")

    headers = [
      {"content-type", "application/x-protobuf"},
      {"content-encoding", "snappy"},
      {"x-prometheus-remote-write-version", "0.1.0"}
    ]

    req_options =
      [method: :post, url: url, headers: headers, receive_timeout: timeout]
      |> Keyword.merge(Application.get_env(:realtime, :metrics_pusher_req_options, []))

    encoded_auth = if auth, do: {:basic, "#{user}:#{auth}"}, else: nil

    state = %__MODULE__{
      push_ref: schedule_push(interval),
      interval: interval,
      req_options: req_options,
      auth: encoded_auth
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:push, state) do
    {exec_time, _} = :timer.tc(fn -> push(state.req_options, state.auth) end, :millisecond)

    if exec_time > :timer.seconds(5) do
      Logger.warning("Metrics push took: #{exec_time} ms")
    end

    {:noreply, %{state | push_ref: schedule_push(state.interval)}}
  end

  def handle_info(msg, state) do
    Logger.error("MetricsPusher received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp schedule_push(delay), do: Process.send_after(self(), :push, delay)

  defp push(req_options, auth) do
    try do
      metrics = Realtime.PromEx.get_metrics() |> IO.iodata_to_binary()
      timestamp_ms = System.system_time(:millisecond)

      case Realtime.PrometheusRemoteWrite.encode(metrics, timestamp_ms) do
        {:ok, body} ->
          case send_metrics(req_options, auth, body) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.error("MetricsPusher: Failed to push metrics to #{req_options[:url]}: #{inspect(reason)}")
              :ok
          end

        {:error, reason} ->
          Logger.error("MetricsPusher: Failed to encode metrics: #{inspect(reason)}")
          :ok
      end
    rescue
      error ->
        Logger.error("MetricsPusher: Exception during push: #{inspect(error)}")
        :ok
    end
  end

  defp send_metrics(req_options, auth, body) do
    opts = [{:body, body} | req_options]
    opts = if auth, do: Keyword.put(opts, :auth, auth), else: opts

    opts |> Req.request() |> handle_response()
  end

  defp handle_response({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp handle_response({:ok, %{status: status} = response}), do: {:error, {:http_error, status, response.body}}
  defp handle_response({:error, reason}), do: {:error, reason}
end
