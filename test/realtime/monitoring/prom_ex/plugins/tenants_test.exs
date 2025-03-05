defmodule Realtime.PromEx.Plugins.TenantsTest do
  alias Realtime.Tenants.Connect
  alias Realtime.Rpc
  use Realtime.DataCase

  alias Realtime.PromEx.Plugins.Tenants

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
      local_tenant = Containers.checkout_tenant()
      remote_tenant = Containers.checkout_tenant()

      on_exit(fn ->
        Containers.checkin_tenant(local_tenant)
        Containers.checkin_tenant(remote_tenant)
      end)

      {:ok, node} = Clustered.start()
      {:ok, _} = Rpc.enhanced_call(node, Connect, :lookup_or_start_connection, [remote_tenant.external_id])
      {:ok, _} = Connect.lookup_or_start_connection(local_tenant.external_id)

      %{local_tenant: local_tenant, remote_tenant: remote_tenant}
    end

    test "conneted based on Connect module information for local node only" do
      Process.sleep(100 * 2)
      assert PromEx.get_metrics(MetricsTest) =~ "realtime_tenants_connected 1"
    end
  end
end
