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
      start_supervised!(MetricsTest)
      local_tenant = Containers.checkout_tenant(true)
      on_exit(fn -> Containers.checkin_tenant(local_tenant) end)
      {:ok, _} = Connect.lookup_or_start_connection(local_tenant.external_id)
      :ok
    end

    test "conneted based on Connect module information for local node only" do
      Process.sleep(2000)
      assert PromEx.get_metrics(MetricsTest) =~ "realtime_tenants_connected 1"
    end
  end
end
