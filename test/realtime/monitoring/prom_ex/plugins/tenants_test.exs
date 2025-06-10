defmodule Realtime.PromEx.Plugins.TenantsTest do
  use Realtime.DataCase, async: false

  alias Realtime.PromEx.Plugins.Tenants
  alias Realtime.Rpc
  alias Realtime.Tenants.Connect

  defmodule MetricsTest do
    use PromEx, otp_app: :realtime_test_tenants
    @impl true
    def plugins do
      [{Tenants, poll_rate: 100}]
    end
  end

  defmodule Test do
    def success, do: {:ok, "success"}
    def failure, do: {:error, "failure"}
  end

  setup do
    local_tenant = Containers.checkout_tenant(run_migrations: true)
    start_supervised!(MetricsTest)
    {:ok, %{tenant: local_tenant}}
  end

  describe "event_metrics" do
    test "success RPC" do
      pattern = ~r/realtime_rpc_count{success="true",tenant="123"}\s(?<number>\d+)/
      # Enough time for the poll rate to be triggered at least once
      Process.sleep(200)
      previous_value = metric_value(pattern)
      assert {:ok, "success"} = Rpc.enhanced_call(node(), Test, :success, [], tenant_id: "123")
      Process.sleep(200)
      assert metric_value(pattern) == previous_value + 1
    end

    test "failure RPC" do
      pattern = ~r/realtime_rpc_count{success="false",tenant="123"}\s(?<number>\d+)/
      # Enough time for the poll rate to be triggered at least once
      Process.sleep(200)
      previous_value = metric_value(pattern)
      assert {:error, "failure"} = Rpc.enhanced_call(node(), Test, :failure, [], tenant_id: "123")
      Process.sleep(200)
      assert metric_value(pattern) == previous_value + 1
    end
  end

  describe "pooling metrics" do
    test "conneted based on Connect module information for local node only", %{tenant: tenant} do
      pattern = ~r/realtime_tenants_connected\s(?<number>\d+)/
      # Enough time for the poll rate to be triggered at least once
      Process.sleep(200)
      previous_value = metric_value(pattern)
      {:ok, _} = Connect.lookup_or_start_connection(tenant.external_id)
      Process.sleep(200)
      assert metric_value(pattern) == previous_value + 1
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
