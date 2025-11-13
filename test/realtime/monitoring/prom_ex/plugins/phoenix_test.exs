defmodule Realtime.PromEx.Plugins.PhoenixTest do
  use Realtime.DataCase, async: false
  alias Realtime.PromEx.Plugins
  alias Realtime.Integration.WebsocketClient

  defmodule MetricsTest do
    use PromEx, otp_app: :realtime_test_phoenix
    @impl true
    def plugins do
      [{Plugins.Phoenix, router: RealtimeWeb.Router, poll_rate: 100, metric_prefix: [:phoenix]}]
    end
  end

  setup do
    start_supervised!(MetricsTest)
    %{tenant: Containers.checkout_tenant(run_migrations: true)}
  end

  describe "pooling metrics" do
    test "number of connections", %{tenant: tenant} do
      {:ok, token} = token_valid(tenant, "anon", %{})

      {:ok, _} =
        WebsocketClient.connect(
          self(),
          uri(tenant, Phoenix.Socket.V1.JSONSerializer, 4002),
          Phoenix.Socket.V1.JSONSerializer,
          [{"x-api-key", token}]
        )

      {:ok, _} =
        WebsocketClient.connect(
          self(),
          uri(tenant, Phoenix.Socket.V1.JSONSerializer, 4002),
          Phoenix.Socket.V1.JSONSerializer,
          [{"x-api-key", token}]
        )

      Process.sleep(200)
      assert metric_value(~r/phoenix_connections_total\s(?<number>\d+)/) >= 2
    end
  end

  describe "event metrics" do
    test "socket connected", %{tenant: tenant} do
      {:ok, token} = token_valid(tenant, "anon", %{})

      {:ok, _} =
        WebsocketClient.connect(
          self(),
          uri(tenant, Phoenix.Socket.V1.JSONSerializer, 4002),
          Phoenix.Socket.V1.JSONSerializer,
          [{"x-api-key", token}]
        )

      {:ok, _} =
        WebsocketClient.connect(
          self(),
          uri(tenant, RealtimeWeb.Socket.V2Serializer, 4002),
          RealtimeWeb.Socket.V2Serializer,
          [{"x-api-key", token}]
        )

      Process.sleep(200)

      assert metric_value(
               ~r/phoenix_socket_connected_duration_milliseconds_count{endpoint="RealtimeWeb.Endpoint",result="ok",serializer="Elixir.Phoenix.Socket.V1.JSONSerializer",transport="websocket"}\s(?<number>\d+)/
             ) == 1

      assert metric_value(
               ~r/phoenix_socket_connected_duration_milliseconds_count{endpoint="RealtimeWeb.Endpoint",result="ok",serializer="Elixir.RealtimeWeb.Socket.V2Serializer",transport="websocket"}\s(?<number>\d+)/
             ) == 1
    end
  end

  defp metric_value(pattern) do
    PromEx.get_metrics(MetricsTest)
    |> String.split("\n", trim: true)
    |> Enum.find_value(
      "0",
      fn item ->
        case Regex.run(pattern, item, capture: ["number"]) do
          [number] -> number
          _ -> false
        end
      end
    )
    |> String.to_integer()
  end
end
