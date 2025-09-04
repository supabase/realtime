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

  describe "pooling metrics" do
    setup do
      start_supervised!(MetricsTest)
      %{tenant: Containers.checkout_tenant(run_migrations: true)}
    end

    test "number of connections", %{tenant: tenant} do
      {:ok, token} = token_valid(tenant, "anon", %{})

      {:ok, _} =
        WebsocketClient.connect(self(), uri(tenant, 4002), Phoenix.Socket.V1.JSONSerializer, [{"x-api-key", token}])

      {:ok, _} =
        WebsocketClient.connect(self(), uri(tenant, 4002), Phoenix.Socket.V1.JSONSerializer, [{"x-api-key", token}])

      Process.sleep(200)
      assert metric_value() >= 2
    end
  end

  defp metric_value() do
    PromEx.get_metrics(MetricsTest)
    |> String.split("\n", trim: true)
    |> Enum.find_value(
      "0",
      fn item ->
        case Regex.run(~r/phoenix_connections_total\s(?<number>\d+)/, item, capture: ["number"]) do
          [number] -> number
          _ -> false
        end
      end
    )
    |> String.to_integer()
  end
end
