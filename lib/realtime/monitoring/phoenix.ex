# copied from https://github.com/akoutmos/prom_ex/blob/master/lib/prom_ex/plugins/phoenix.ex

if Code.ensure_loaded?(Phoenix) do
  defmodule Realtime.PromEx.Plugins.Phoenix do
    @moduledoc """
    This plugin captures metrics emitted by Phoenix. Specifically, it captures HTTP request metrics and
    Phoenix channel metrics.

    ## Plugin options

    This plugin supports the following options:
    - `metric_prefix`: This option is OPTIONAL and is used to override the default metric prefix of
      `[otp_app, :prom_ex, :phoenix]`. If this changes you will also want to set `phoenix_metric_prefix`
      in your `dashboard_assigns` to the snakecase version of your prefix, the default
      `phoenix_metric_prefix` is `{otp_app}_prom_ex_phoenix`.

    ### Single Endpoint/Router
    - `router`: This option is REQUIRED and is the full module name of your Phoenix Router (e.g MyAppWeb.Router).

    - `endpoint`: This is a REQUIRED option and is the full module name of your Phoenix Endpoint (e.g MyAppWeb.Endpoint).

    - `event_prefix`: This option is OPTIONAL and allows you to set the event prefix for the Telemetry events. This
      value should align with what you pass to `Plug.Telemetry` in your `endpoint.ex` file (see the plug docs
      for more information https://hexdocs.pm/plug/Plug.Telemetry.html) This value should align with what you pass
      to `Plug.Telemetry` in your `endpoint.ex` file (see the plug docs for more
      information https://hexdocs.pm/plug/Plug.Telemetry.html)

    - `additional_routes`: This option is OPTIONAL and allows you to specify route path labels for applications routes
      not defined in your Router module.

      For example, if you want to track telemetry events for a plug in your
      `endpoint.ex` file, you can provide a keyword list with the structure `[some-route: ~r(\/some-path)]` and any
      time that the route is called and the plug handles the call, the path label for this particular Prometheus metric
      will be set to `some-route`. You can pass in either a regular expression or a string to match the incoming
      request.

    #### Example plugin configuration

    ```elixir
    {
      PromEx.Plugins.Phoenix,
      endpoint: MyApp.Endpoint,
      router: MyAppWeb.Public.Router,
      event_prefix: [:admin, :endpoint]
    }
    ```

    ### Multiple Endpoints/Router

    - `endpoints`: This accepts a list of per Phoenix Endpoint options `{endpoint_name, endpoint_opts}`
      - `endpoint_name`: This option is REQUIRED and is the full module name of your Phoenix Endpoint (e.g MyAppWeb.Endpoint).

      - `endpoint_opts`: Per endpoint plugin options:
        - `:routers`: This option is REQUIRED and lists all of routers modules for the endpoint, the HTTP metrics will
          be augmented with controller/action/path information from the routers.

        - `:event_prefix`: This option is OPTIONAL and allows you to set the event prefix for the Telemetry events. This
        value should align with what you pass to `Plug.Telemetry` in the  corresponding endpoint module (see the plug docs
        for more information https://hexdocs.pm/plug/Plug.Telemetry.html)

        - `:additional_routes`: This option is OPTIONAL and allows you to specify route path labels for applications routes
        not defined in your Router modules for the corresponding endpoint.

    #### Example plugin configuration

    ```elixir
    {
      PromEx.Plugins.Phoenix,
      endpoints: [
        {MyApp.Endpoint, routers: [MyAppWeb.Public.Router]},
        {MyApp.Endpoint2, routers: [MyAppWeb.Admin.Router], event_prefix: [:admin, :endpoint]}
      ]
    }
    ```

    ## Metric Groups

    This plugin exposes the following metric groups:
    - `:phoenix_http_event_metrics`
    - `:phoenix_channel_event_metrics`
    - `:phoenix_socket_event_metrics`
    - `:phoenix_endpoint_manual_metrics`

    ## Usage

    To use plugin in your application, add the following to your PromEx module:

    ```elixir
    defmodule WebApp.PromEx do
      use PromEx, otp_app: :web_app

      @impl true
      def plugins do
        [
          ...
          {
            PromEx.Plugins.Phoenix,
            endpoint: MyApp.Endpoint,
            router: MyAppWeb.Public.Router
          }
        ]
      end

      @impl true
      def dashboards do
        [
          ...
          {:prom_ex, "phoenix.json"}
        ]
      end
    end
    ```

    When working with multiple Phoenix routers use the `endpoints` option instead:

    ```elixir
    defmodule WebApp.PromEx do
      use PromEx, otp_app: :web_app

      @impl true
      def plugins do
        [
          ...
          {
            PromEx.Plugins.Phoenix,
            endpoints: [
              {MyApp.Endpoint, routers: [MyAppWeb.Public.Router]},
              {MyApp.Endpoint2, routers: [MyAppWeb.Admin.Router], event_prefix: [:admin, :endpoint]}
            ]
          }
        ]
      end

      @impl true
      def dashboards do
        [
          ...
          {:prom_ex, "phoenix.json"}
        ]
      end
    end
    ```
    """

    use PromEx.Plugin

    require Logger

    alias Phoenix.Socket
    alias Plug.Conn

    @stop_event [:prom_ex, :plugin, :phoenix, :stop]

    @impl true
    def event_metrics(opts) do
      otp_app = Keyword.fetch!(opts, :otp_app)
      metric_prefix = Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :phoenix))
      phoenix_event_prefixes = fetch_event_prefixes!(opts)

      set_up_telemetry_proxy(phoenix_event_prefixes)

      # Event metrics definitions
      [
        channel_events(metric_prefix),
        socket_events(metric_prefix)
      ]
    end

    defp channel_events(metric_prefix) do
      Event.build(
        :phoenix_channel_event_metrics,
        [
          # Capture the number of channel joins that have occurred
          counter(
            metric_prefix ++ [:channel, :joined, :total],
            event_name: [:phoenix, :channel_joined],
            description: "The number of channel joins that have occurred.",
            tag_values: fn %{
                             result: result,
                             socket: %Socket{transport: transport, endpoint: endpoint}
                           } ->
              %{
                transport: transport,
                result: result,
                endpoint: normalize_module_name(endpoint)
              }
            end,
            tags: [:result, :transport, :endpoint]
          ),

          # Capture channel handle_in duration
          distribution(
            metric_prefix ++ [:channel, :handled_in, :duration, :milliseconds],
            event_name: [:phoenix, :channel_handled_in],
            measurement: :duration,
            description: "The time it takes for the application to respond to channel messages.",
            reporter_options: [
              buckets: [10, 100, 500, 1_000, 5_000, 10_000]
            ],
            tag_values: fn %{socket: %Socket{endpoint: endpoint}} ->
              %{
                endpoint: normalize_module_name(endpoint)
              }
            end,
            tags: [:endpoint],
            unit: {:native, :millisecond}
          )
        ]
      )
    end

    defp socket_events(metric_prefix) do
      Event.build(
        :phoenix_socket_event_metrics,
        [
          # Capture socket connection duration
          distribution(
            metric_prefix ++ [:socket, :connected, :duration, :milliseconds],
            event_name: [:phoenix, :socket_connected],
            measurement: :duration,
            description:
              "The time it takes for the application to establish a socket connection.",
            reporter_options: [
              buckets: [10, 100, 500, 1_000, 5_000, 10_000]
            ],
            tag_values: fn %{result: result, endpoint: endpoint, transport: transport} ->
              %{
                transport: transport,
                result: result,
                endpoint: normalize_module_name(endpoint)
              }
            end,
            tags: [:result, :transport, :endpoint],
            unit: {:native, :millisecond}
          )
        ]
      )
    end

    defp get_conn_tags(routers, additional_routes) do
      fn
        %{conn: %Conn{} = conn} ->
          default_route_tags = handle_additional_routes_check(conn, additional_routes)

          conn
          |> do_get_router_info(routers, default_route_tags)
          |> Map.merge(%{
            status: conn.status,
            method: conn.method
          })

        _ ->
          Logger.warning("Could not resolve path for request")
      end
    end

    defp do_get_router_info(conn, routers, default_route_tags) do
      routers
      |> Enum.find_value(default_route_tags, fn router ->
        case Phoenix.Router.route_info(router, conn.method, conn.request_path, "") do
          :error ->
            false

          %{route: path, plug: controller, plug_opts: action} ->
            %{
              path: path,
              controller: normalize_module_name(controller),
              action: normalize_action(action)
            }
        end
      end)
    end

    defp handle_additional_routes_check(%Conn{request_path: request_path}, additional_routes) do
      default_tags = %{
        path: "Unknown",
        controller: "Unknown",
        action: "Unknown"
      }

      additional_routes
      |> Enum.find_value(default_tags, fn {path_label, route_check} ->
        cond do
          is_binary(route_check) and route_check == request_path ->
            %{
              path: path_label,
              controller: "NA",
              action: "NA"
            }

          match?(%Regex{}, route_check) and Regex.match?(route_check, request_path) ->
            %{
              path: path_label,
              controller: "NA",
              action: "NA"
            }

          true ->
            false
        end
      end)
    end

    defp set_up_telemetry_proxy(phoenix_event_prefixes) do
      phoenix_event_prefixes
      |> Enum.each(fn telemetry_prefix ->
        stop_event = telemetry_prefix ++ [:stop]

        :telemetry.attach(
          [:prom_ex, :phoenix, :proxy] ++ telemetry_prefix,
          stop_event,
          &__MODULE__.handle_proxy_phoenix_event/4,
          %{}
        )
      end)
    end

    @doc false
    def handle_proxy_phoenix_event(_event_name, event_measurement, event_metadata, _config) do
      :telemetry.execute(@stop_event, event_measurement, event_metadata)
    end

    defp normalize_module_name(name) when is_atom(name) do
      name
      |> Atom.to_string()
      |> String.trim_leading("Elixir.")
    end

    defp normalize_module_name(name), do: name

    defp normalize_action(action) when is_atom(action), do: action
    defp normalize_action(_action), do: "Unknown"

    defp fetch_additional_routes!(opts) do
      opts
      |> fetch_either!(:router, :endpoints)
      |> case do
        endpoints when is_list(endpoints) ->
          endpoints
          |> Enum.flat_map(fn
            {_endpoint, endpoint_opts} ->
              Keyword.get(endpoint_opts, :additional_routes, [])
          end)
          |> MapSet.new()
          |> MapSet.to_list()

        _router ->
          Keyword.get(opts, :additional_routes, [])
      end
    end

    defp fetch_event_prefixes!(opts) do
      opts
      |> fetch_either!(:router, :endpoints)
      |> case do
        endpoints when is_list(endpoints) ->
          endpoints
          |> Enum.map(fn
            {_endpoint, endpoint_opts} ->
              Keyword.get(endpoint_opts, :event_prefix, [:phoenix, :endpoint])
          end)

        _router ->
          [Keyword.get(opts, :event_prefix, [:phoenix, :endpoint])]
      end
      |> MapSet.new()
      |> MapSet.to_list()
    end

    defp fetch_routers!(opts) do
      opts
      |> fetch_either!(:router, :endpoints)
      |> case do
        endpoints when is_list(endpoints) ->
          endpoints
          |> Enum.flat_map(fn
            {_endpoint, endpoint_opts} ->
              endpoint_opts
              |> Keyword.fetch!(:routers)
          end)
          |> MapSet.new()
          |> MapSet.to_list()

        router ->
          [router]
      end
    end

    defp fetch_either!(keywordlist, key1, key2) do
      case {Keyword.has_key?(keywordlist, key1), Keyword.has_key?(keywordlist, key2)} do
        {true, _} ->
          keywordlist[key1]

        {false, true} ->
          keywordlist[key2]

        {false, false} ->
          raise KeyError,
                "Neither #{inspect(key1)} nor #{inspect(key2)} found in #{inspect(keywordlist)}"
      end
    end
  end
else
  defmodule PromEx.Plugins.Phoenix do
    @moduledoc false
    use PromEx.Plugin

    @impl true
    def event_metrics(_opts) do
      PromEx.Plugin.no_dep_raise(__MODULE__, "Phoenix")
    end
  end
end
