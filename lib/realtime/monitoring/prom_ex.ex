defmodule Realtime.PromEx do
  alias Realtime.PromEx.Plugins.{OsMon, Phoenix, Tenants, Tenant}

  import Realtime.Helpers, only: [short_node_id: 0]

  @moduledoc """
  Be sure to add the following to finish setting up PromEx:

  1. Update your configuration (config.exs, dev.exs, prod.exs, releases.exs, etc) to
     configure the necessary bit of PromEx. Be sure to check out `PromEx.Config` for
     more details regarding configuring PromEx:
     ```
     config :realtime, Realtime.PromEx,
       disabled: false,
       manual_metrics_start_delay: :no_delay,
       drop_metrics_groups: [],
       grafana: :disabled,
       metrics_server: :disabled
     ```

  2. Add this module to your application supervision tree. It should be one of the first
     things that is started so that no Telemetry events are missed. For example, if PromEx
     is started after your Repo module, you will miss Ecto's init events and the dashboards
     will be missing some data points:
     ```
     def start(_type, _args) do
       children = [
         Realtime.PromEx,

         ...
       ]

       ...
     end
     ```

  3. Update your `endpoint.ex` file to expose your metrics (or configure a standalone
     server using the `:metrics_server` config options). Be sure to put this plug before
     your `Plug.Telemetry` entry so that you can avoid having calls to your `/metrics`
     endpoint create their own metrics and logs which can pollute your logs/metrics given
     that Prometheus will scrape at a regular interval and that can get noisy:
     ```
     defmodule RealtimeWeb.Endpoint do
       use Phoenix.Endpoint, otp_app: :realtime

       ...

       plug PromEx.Plug, prom_ex_module: Realtime.PromEx

       ...
     end
     ```

  4. Update the list of plugins in the `plugins/0` function return list to reflect your
     application's dependencies. Also update the list of dashboards that are to be uploaded
     to Grafana in the `dashboards/0` function.
  """

  use PromEx, otp_app: :realtime

  alias PromEx.Plugins

  @impl true
  def plugins do
    poll_rate = Application.get_env(:realtime, :prom_poll_rate)

    [
      # PromEx built in plugins
      # Plugins.Application,
      {Plugins.Beam, poll_rate: poll_rate, metric_prefix: [:beam]},
      {Phoenix, router: RealtimeWeb.Router, poll_rate: poll_rate, metric_prefix: [:phoenix]},
      # {Plugins.Ecto, poll_rate: poll_rate, metric_prefix: [:ecto]},
      # Plugins.Oban,
      # Plugins.PhoenixLiveView
      {OsMon, poll_rate: poll_rate},
      {Tenants, poll_rate: poll_rate},
      {Tenant, poll_rate: poll_rate}
    ]
  end

  @impl true
  def dashboard_assigns do
    [
      datasource_id: "YOUR_PROMETHEUS_DATASOURCE_ID"
    ]
  end

  @impl true
  def dashboards do
    [
      # PromEx built in Grafana dashboards
      # {:prom_ex, "application.json"},
      # {:prom_ex, "beam.json"},
      # {:prom_ex, "phoenix.json"}
      # {:prom_ex, "ecto.json"},
      # {:prom_ex, "oban.json"},
      # {:prom_ex, "phoenix_live_view.json"}

      # Add your dashboard definitions here with the format: {:otp_app, "path_in_priv"}
      # {:realtime, "/grafana_dashboards/user_metrics.json"}
    ]
  end

  def get_metrics() do
    %{
      region: region,
      node_host: node_host,
      short_alloc_id: short_alloc_id
    } = get_metrics_tags()

    def_tags = "host=\"#{node_host}\",region=\"#{region}\",id=\"#{short_alloc_id}\""

    metrics =
      PromEx.get_metrics(Realtime.PromEx)
      |> String.split("\n")
      |> Enum.map(fn line ->
        case Regex.run(~r/(?!\#)^(\w+)(?:{(.*?)})?\s*(.+)$/, line) do
          nil ->
            line

          [_, key, tags, value] ->
            tags =
              if tags == "" do
                def_tags
              else
                tags <> "," <> def_tags
              end

            "#{key}{#{tags}} #{value}"
        end
      end)
      |> Enum.join("\n")

    Realtime.PromEx.__ets_cron_flusher_name__()
    |> PromEx.ETSCronFlusher.defer_ets_flush()

    metrics
  end

  def set_metrics_tags() do
    [_, node_host] = node() |> Atom.to_string() |> String.split("@")

    metrics_tags = %{
      region: Application.get_env(:realtime, :fly_region),
      node_host: node_host,
      short_alloc_id: short_node_id()
    }

    Application.put_env(:realtime, :metrics_tags, metrics_tags)
  end

  def get_metrics_tags() do
    Application.get_env(:realtime, :metrics_tags)
  end
end
