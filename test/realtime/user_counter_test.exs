defmodule Realtime.UsersCounterTest do
  use Realtime.DataCase, async: false
  alias Realtime.UsersCounter
  alias Realtime.Rpc

  describe "add/1" do
    test "starts counter for tenant" do
      assert UsersCounter.add(self(), random_string()) == :ok
    end
  end

  @aux_mod (quote do
              defmodule Aux do
                def ping(),
                  do:
                    spawn(fn ->
                      Process.sleep(3000)
                      :pong
                    end)
              end
            end)

  Code.eval_quoted(@aux_mod)

  describe "tenant_users/1" do
    test "returns count of connected clients for tenant on cluster node" do
      tenant_id = random_string()
      expected = generate_load(tenant_id)
      Process.sleep(1000)
      assert UsersCounter.tenant_users(tenant_id) == expected
    end
  end

  describe "tenant_users/2" do
    test "returns count of connected clients for tenant on target cluster" do
      tenant_id = random_string()
      generate_load(tenant_id)
      {:ok, node} = Clustered.start(@aux_mod)
      pid = Rpc.call(node, Aux, :ping, [])
      UsersCounter.add(pid, tenant_id)
      assert UsersCounter.tenant_users(node, tenant_id) == 1
    end
  end

  defp generate_load(tenant_id, nodes \\ 2, processes \\ 2) do
    for _ <- 1..nodes do
      {:ok, node} = Clustered.start(@aux_mod)

      for _ <- 1..processes do
        pid = Rpc.call(node, Aux, :ping, [])

        for _ <- 1..10 do
          # replicate same pid added multiple times concurrently
          Task.start(fn ->
            UsersCounter.add(pid, tenant_id)
          end)

          # noisy neighbors to test handling of bigger loads on concurrent calls
          Task.start(fn ->
            pid = Rpc.call(node, Aux, :ping, [])
            UsersCounter.add(pid, random_string())
          end)
        end
      end
    end

    nodes * processes
  end
end
