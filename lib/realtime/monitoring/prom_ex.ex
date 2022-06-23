defmodule Realtime.PromEx do
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
    [
      # PromEx built in plugins
      # Plugins.Application,
      Plugins.Beam,
      {Plugins.Phoenix, router: RealtimeWeb.Router},
      Plugins.Ecto,
      # Plugins.Oban,
      # Plugins.PhoenixLiveView
      Realtime.PromEx.Plugins.OsMon
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
end
