defmodule Realtime.PromEx.Plugins.TenantsTest do
  use Realtime.DataCase, async: false

  alias Realtime.PromEx.Plugins.Tenants
  alias Realtime.Tenants.Connect

  defmodule MetricsTest do
    use PromEx, otp_app: :realtime_test_tenants
    @impl true
    def plugins do
      [{Tenants, poll_rate: 100}]
    end
  end

  describe "pooling metrics" do
    setup do
      local_tenant = Containers.checkout_tenant(run_migrations: true)
      start_supervised!(MetricsTest)
      {:ok, %{tenant: local_tenant}}
    end

    test "conneted based on Connect module information for local node only", %{tenant: tenant} do
      # Enough time for the poll rate to be triggered at least once
      Process.sleep(200)
      previous_value = metric_value()
      {:ok, _} = Connect.lookup_or_start_connection(tenant.external_id)
      Process.sleep(200)
      assert metric_value() == previous_value + 1
    end
  end

  defp metric_value() do
    PromEx.get_metrics(MetricsTest)
    |> String.split("\n", trim: true)
    |> Enum.find_value(
      "0",
      fn item ->
        case Regex.run(~r/realtime_tenants_connected\s(?<number>\d+)/, item, capture: ["number"]) do
          [number] -> number
          _ -> false
        end
      end
    )
    |> String.to_integer()
  end
end
