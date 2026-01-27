defmodule Realtime.MetricsPusher do
  @moduledoc """
  GenServer that periodically pushes Prometheus metrics to an endpoint.

  Only starts if `url` is configured.
  Pushes metrics every 30 seconds (configurable) to the configured URL endpoint.
  """

  use GenServer
  require Logger

  defstruct [:push_ref, :interval, :req_options]

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

    compress =
      Keyword.get(
        opts,
        :compress,
        Application.get_env(:realtime, :metrics_pusher_compress, true)
      )

    Logger.info("Starting MetricsPusher (url: #{url}, interval: #{interval}ms, compress: #{compress})")

    headers =
      if auth do
        [{"authorization", auth}, {"content-type", "text/plain"}]
      else
        [{"content-type", "text/plain"}]
      end

    req_options = [
      method: :post,
      url: url,
      headers: headers,
      compress_body: compress,
      receive_timeout: timeout
    ]

    req_options = Keyword.merge(req_options, Application.get_env(:realtime, :metrics_pusher_req_options, []))

    state = %__MODULE__{push_ref: schedule_push(interval), interval: interval, req_options: req_options}

    {:ok, state}
  end

  @impl true
  def handle_info(:push, state) do
    Process.cancel_timer(state.push_ref)

    {exec_time, _} = :timer.tc(fn -> push(state.req_options) end, :millisecond)

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

  defp push(req_options) do
    try do
      metrics = Realtime.PromEx.get_metrics()

      case send_metrics(req_options, metrics) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("MetricsPusher: Failed to push metrics to #{req_options[:url]}: #{inspect(reason)}")
          :ok
      end
    rescue
      error ->
        Logger.error("MetricsPusher: Exception during push: #{inspect(error)}")
        :ok
    end
  end

  defp send_metrics(req_options, metrics) do
    [{:body, metrics} | req_options]
    |> Req.request()
    |> case do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status} = response} ->
        {:error, {:http_error, status, response.body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
