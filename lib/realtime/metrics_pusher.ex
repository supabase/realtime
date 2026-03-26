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

    compress =
      Keyword.get(
        opts,
        :compress,
        Application.get_env(:realtime, :metrics_pusher_compress, true)
      )

    extra_labels =
      Keyword.get(
        opts,
        :extra_labels,
        Application.get_env(:realtime, :metrics_pusher_extra_labels, [])
      )

    params = Enum.map(extra_labels, fn {k, v} -> {:extra_label, "#{k}=#{v}"} end)

    Logger.info("Starting MetricsPusher (url: #{url}, interval: #{interval}ms, compress: #{compress})")

    headers = [{"content-type", "text/plain"}]

    basic_auth = if auth, do: [auth: {:basic, "#{user}:#{auth}"}], else: []

    req_options =
      [
        method: :post,
        url: url,
        headers: headers,
        compress_body: compress,
        receive_timeout: timeout,
        params: params
      ]
      |> Keyword.merge(basic_auth)
      |> Keyword.merge(Application.get_env(:realtime, :metrics_pusher_req_options, []))

    state = %__MODULE__{
      push_ref: schedule_push(interval),
      interval: interval,
      req_options: req_options
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:push, state) do
    {exec_time, _} = :timer.tc(fn -> push(state.req_options) end, :millisecond)

    if exec_time > :timer.seconds(5) do
      Logger.warning("Metrics push took: #{exec_time} ms")
    end

    {:noreply, %{state | push_ref: schedule_push(state.interval)}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.error("MetricsPusher received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp schedule_push(delay), do: Process.send_after(self(), :push, delay)

  defp push(req_options) do
    tasks = [
      Task.Supervisor.async_nolink(Realtime.TaskSupervisor, fn ->
        push_metrics("global", &Realtime.PromEx.get_global_metrics/0, req_options)
      end),
      Task.Supervisor.async_nolink(Realtime.TaskSupervisor, fn ->
        push_metrics("tenant", &Realtime.TenantPromEx.get_metrics/0, req_options)
      end)
    ]

    tasks
    |> Task.yield_many(:timer.minutes(1))
    |> Enum.each(fn
      {task, nil} ->
        Task.shutdown(task, :brutal_kill)
        Logger.error("MetricsPusher: Task timed out: #{inspect(task)}")

      {_task, {:exit, reason}} ->
        Logger.error("MetricsPusher: Task exited with reason: #{inspect(reason)}")

      {_task, {:ok, _}} ->
        :ok
    end)
  end

  defp push_metrics(label, get_metrics_fn, req_options) do
    try do
      metrics = get_metrics_fn.()

      case send_metrics(req_options, metrics) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("MetricsPusher: Failed to push #{label} metrics to #{req_options[:url]}: #{inspect(reason)}")
          :ok
      end
    rescue
      error ->
        Logger.error("MetricsPusher: Exception during #{label} push: #{inspect(error)}")
        :ok
    end
  end

  defp send_metrics(req_options, metrics) do
    [{:body, metrics} | req_options] |> Req.request() |> handle_response()
  end

  defp handle_response({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp handle_response({:ok, %{status: status} = response}), do: {:error, {:http_error, status, response.body}}
  defp handle_response({:error, reason}), do: {:error, reason}
end
