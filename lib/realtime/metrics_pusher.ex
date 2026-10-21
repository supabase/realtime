defmodule Realtime.MetricsPusher do
  @moduledoc """
  GenServer that periodically pushes Prometheus metrics to one or more endpoints.

  Each pusher runs with a `:scope`:

    * `:all` (default) pushes both global and tenant metrics to the `metrics_pusher_*` endpoint.
    * `:global` pushes only global metrics to the `metrics_pusher_*` endpoint.
    * `:tenant` pushes only tenant metrics to the `tenant_metrics_pusher_*` endpoint.

  This lets global and tenant metrics go to different endpoints (central vs. regional).
  See `child_specs/1` for how the scopes are chosen from config.

  Each scope takes a list of `urls` and pushes every metric set to every URL, with the same auth
  and extra labels. This lets metrics go to an old and a new endpoint at the same time during a
  migration.

  Only starts if the scope has at least one URL configured.
  Pushes metrics every 30 seconds (configurable) to each configured URL.
  """

  use GenServer
  use Realtime.Logs

  require Logger

  @type scope :: :all | :global | :tenant

  defstruct [:scope, :push_ref, :interval, :req_options, :urls]

  @doc """
  Child specs for the pushers to start, based on which pushers are enabled.

  Without the tenant pusher, one `:all` pusher sends both metric sets (if enabled).
  With the tenant pusher, the `metrics_pusher_*` pusher sends global metrics only (if enabled)
  and a separate `:tenant` pusher sends tenant metrics.

  Defaults to the `:metrics_pusher_enabled` and `:tenant_metrics_pusher_enabled` app env.
  """
  @spec child_specs(keyword()) :: [Supervisor.child_spec()]
  def child_specs(opts \\ []) do
    metrics_enabled = Keyword.get(opts, :metrics_enabled, Application.get_env(:realtime, :metrics_pusher_enabled))

    tenant_enabled =
      Keyword.get(opts, :tenant_enabled, Application.get_env(:realtime, :tenant_metrics_pusher_enabled))

    cond do
      metrics_enabled and tenant_enabled ->
        [
          scoped_child_spec(:global, __MODULE__.Global),
          scoped_child_spec(:tenant, __MODULE__.Tenant)
        ]

      metrics_enabled ->
        [scoped_child_spec(:all, __MODULE__)]

      true ->
        []
    end
  end

  @spec start_link(keyword()) :: {:ok, pid()} | :ignore
  def start_link(opts) do
    scope = Keyword.get(opts, :scope, :all)
    urls = Keyword.get(opts, :urls, get_env(scope, :urls, []))
    name = Keyword.get(opts, :name, __MODULE__)

    if urls != [] do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      Logger.warning("MetricsPusher (scope: #{scope}) not started: urls must be configured")

      :ignore
    end
  end

  @impl true
  def init(opts) do
    scope = Keyword.get(opts, :scope, :all)
    urls = Keyword.get(opts, :urls, get_env(scope, :urls, []))
    user = Keyword.get(opts, :user, get_env(scope, :user, "realtime"))
    auth = Keyword.get(opts, :auth, get_env(scope, :auth))
    interval = Keyword.get(opts, :interval, get_env(scope, :interval_ms, to_timeout(second: 30)))
    timeout = Keyword.get(opts, :timeout, get_env(scope, :timeout_ms, to_timeout(second: 15)))
    compress = Keyword.get(opts, :compress, get_env(scope, :compress, true))
    extra_labels = Keyword.get(opts, :extra_labels, get_env(scope, :extra_labels, []))

    params = Enum.map(extra_labels, fn {k, v} -> {:extra_label, "#{k}=#{v}"} end)

    Logger.info(
      "Starting MetricsPusher (scope: #{scope}, urls: #{Enum.join(urls, ", ")}, interval: #{interval}ms, compress: #{compress})"
    )

    headers = [{"content-type", "text/plain"}]

    basic_auth = if auth, do: [auth: {:basic, "#{user}:#{auth}"}], else: []

    req_options =
      [
        method: :post,
        headers: headers,
        compress_body: compress,
        receive_timeout: timeout,
        params: params
      ]
      |> Keyword.merge(basic_auth)
      |> Keyword.merge(Application.get_env(:realtime, :metrics_pusher_req_options, []))

    state = %__MODULE__{
      scope: scope,
      push_ref: schedule_push(interval),
      interval: interval,
      req_options: req_options,
      urls: urls
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:push, state) do
    {exec_time, _} = :timer.tc(fn -> push(state.scope, state.urls, state.req_options) end, :millisecond)

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

  defp scoped_child_spec(scope, name), do: Supervisor.child_spec({__MODULE__, scope: scope, name: name}, id: name)

  defp schedule_push(delay), do: Process.send_after(self(), :push, delay)

  # Fetches each metric set once and sends that body to every URL, one task per {set, URL} pair,
  # so a slow or failing URL doesn't hold up the others. `TenantPromEx.get_metrics/0` also
  # schedules an ETS flush, so it must not run once per URL.
  defp push(scope, urls, req_options) do
    scope
    |> sources()
    |> Enum.flat_map(fn {label, get_metrics_fn} ->
      case fetch_metrics(label, get_metrics_fn) do
        {:ok, metrics} ->
          Enum.map(urls, fn url ->
            Task.Supervisor.async_nolink(Realtime.TaskSupervisor, fn ->
              push_metrics(label, metrics, [{:url, url} | req_options])
            end)
          end)

        :error ->
          []
      end
    end)
    |> Task.yield_many(to_timeout(minute: 1))
    |> Enum.each(fn
      {task, nil} ->
        Task.shutdown(task, :brutal_kill)
        log_error("MetricsPusherTimeout", "MetricsPusher: Task timed out: #{inspect(task)}")

      {_task, {:exit, reason}} ->
        log_error("MetricsPusherTaskExited", "MetricsPusher: Task exited with reason: #{inspect(reason)}")

      {_task, {:ok, _}} ->
        :ok
    end)
  end

  defp sources(:all), do: sources(:global) ++ sources(:tenant)
  defp sources(:global), do: [{"global", &Realtime.PromEx.get_global_metrics/0}]
  defp sources(:tenant), do: [{"tenant", &Realtime.TenantPromEx.get_metrics/0}]

  defp fetch_metrics(label, get_metrics_fn) do
    {:ok, get_metrics_fn.()}
  rescue
    error ->
      log_error("MetricsPusherException", "MetricsPusher: Exception fetching #{label} metrics: #{inspect(error)}")
      :error
  end

  defp push_metrics(label, metrics, req_options) do
    case send_metrics(req_options, metrics) do
      :ok ->
        :ok

      {:error, reason} ->
        log_error(
          "MetricsPusherFailed",
          "MetricsPusher: Failed to push #{label} metrics to #{req_options[:url]}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    error ->
      log_error("MetricsPusherException", "MetricsPusher: Exception during #{label} push: #{inspect(error)}")
      :ok
  end

  defp send_metrics(req_options, metrics) do
    [{:body, metrics} | req_options] |> Req.request() |> handle_response()
  end

  defp handle_response({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp handle_response({:ok, %{status: status} = response}), do: {:error, {:http_error, status, response.body}}
  defp handle_response({:error, reason}), do: {:error, reason}

  defp get_env(scope, key, default \\ nil), do: Application.get_env(:realtime, config_key(scope, key), default)

  defp config_key(:tenant, key), do: :"tenant_metrics_pusher_#{key}"
  defp config_key(_scope, key), do: :"metrics_pusher_#{key}"
end
