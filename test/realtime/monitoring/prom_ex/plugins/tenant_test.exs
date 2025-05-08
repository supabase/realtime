defmodule Realtime.PromEx.Plugins.TenantTest do
  use Realtime.DataCase

  alias Realtime.PromEx.Plugins.Tenant
  alias Realtime.Rpc
  alias Realtime.UsersCounter

  def handle_telemetry(event, metadata, content, pid: pid), do: send(pid, {event, metadata, content})

  @aux_mod (quote do
              defmodule FakeUserCounter do
                def fake_add(external_id) do
                  :ok = UsersCounter.add(spawn(fn -> Process.sleep(2000) end), external_id)
                end
              end
            end)

  Code.eval_quoted(@aux_mod)

  describe "execute_tenant_metrics/0" do
    setup do
      tenant = Containers.checkout_tenant()
      :telemetry.attach(__MODULE__, [:realtime, :connections], &__MODULE__.handle_telemetry/4, pid: self())

      on_exit(fn -> :telemetry.detach(__MODULE__) end)

      {:ok, node} = Clustered.start(@aux_mod)
      %{tenant: tenant, node: node}
    end

    test "returns a list of tenant metrics and handles bad tenant ids", %{
      tenant: %{external_id: external_id},
      node: node
    } do
      UsersCounter.add(self(), external_id)
      # Add bad tenant id
      UsersCounter.add(self(), random_string())

      _ = Rpc.call(node, FakeUserCounter, :fake_add, [external_id])
      Process.sleep(500)
      Tenant.execute_tenant_metrics()

      assert_receive {[:realtime, :connections], %{connected: 1, limit: 200, connected_cluster: 2},
                      %{tenant: ^external_id}}

      refute_receive :_
    end
  end
end
