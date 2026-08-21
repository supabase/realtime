defmodule Realtime.UsersCounterTest do
  use Realtime.DataCase, async: false
  alias Realtime.UsersCounter
  alias Realtime.Rpc

  setup_all do
    tenant_id = random_string()
    count = generate_load(tenant_id)

    %{tenant_id: tenant_id, count: count, nodes: Node.list()}
  end

  describe "already_counted?/2" do
    test "returns true if pid already counted for tenant", %{tenant_id: tenant_id} do
      pid = self()
      assert UsersCounter.add(pid, tenant_id) == :ok
      assert UsersCounter.already_counted?(pid, tenant_id) == true
    end

    test "returns false if pid not counted for tenant" do
      assert UsersCounter.already_counted?(self(), random_string()) == false
    end
  end

  describe "add/1" do
    test "starts counter for tenant" do
      assert UsersCounter.add(self(), random_string()) == :ok
    end
  end

  describe "local_tenants/0" do
    test "returns list of tenant ids with local connections" do
      tenant_id = random_string()
      assert UsersCounter.add(self(), tenant_id) == :ok

      tenants = UsersCounter.local_tenants()
      assert is_list(tenants)
      assert tenant_id in tenants
    end
  end

  @aux_mod (quote do
              defmodule Aux do
                def ping() do
                  spawn(fn -> Process.sleep(:infinity) end)
                end

                def join(pid, group) do
                  UsersCounter.add(pid, group)
                end
              end
            end)

  Code.eval_quoted(@aux_mod)

  describe "tenant_counts/0" do
    test "map of tenant and number of users", %{tenant_id: tenant_id, count: expected} do
      assert UsersCounter.add(self(), tenant_id) == :ok
      Process.sleep(1000)
      counts = UsersCounter.tenant_counts()

      assert counts[tenant_id] == expected + 1
      assert map_size(counts) >= 61

      counts = Forum.Census.local_member_counts(:users)

      assert counts[tenant_id] == 1
      assert map_size(counts) >= 1

      counts = Forum.Census.member_counts(:users)

      assert counts[tenant_id] == expected + 1
      assert map_size(counts) >= 61
    end
  end

  describe "local_tenant_counts/0" do
    test "map of tenant and number of users for local node only", %{tenant_id: tenant_id} do
      assert UsersCounter.add(self(), tenant_id) == :ok

      my_counts = UsersCounter.local_tenant_counts()
      # Only one connection from this test process on this node
      assert %{^tenant_id => 1} = my_counts
    end
  end

  describe "tenant_users/1" do
    test "returns count of connected clients for tenant on cluster node", %{tenant_id: tenant_id, count: expected} do
      Process.sleep(1000)
      assert UsersCounter.tenant_users(tenant_id) == expected
    end
  end

  defp generate_load(tenant_id) do
    processes = 2

    gen_rpc_port = Application.fetch_env!(:gen_rpc, :tcp_server_port)

    peers = [{:us_node, "us-east-1"}, {:ap2_nodeX, "ap-southeast-2"}, {:ap2_nodeY, "ap-southeast-2"}]

    nodes =
      Map.new([
        {node(), gen_rpc_port}
        | Enum.map(peers, fn {peer, _} -> {TestEnv.peer_node(peer), TestEnv.peer_gen_rpc_port(peer)} end)
      ])

    on_exit(fn -> Application.put_env(:gen_rpc, :client_config_per_node, {:internal, %{}}) end)
    Application.put_env(:gen_rpc, :client_config_per_node, {:internal, nodes})

    Enum.each(peers, fn {peer, region} ->
      extra_config = [
        {:gen_rpc, :tcp_server_port, TestEnv.peer_gen_rpc_port(peer)},
        {:gen_rpc, :client_config_per_node, {:internal, nodes}},
        {:realtime, :users_scope_broadcast_interval_in_ms, 100},
        {:realtime, :region, region}
      ]

      {:ok, node} =
        Clustered.start(@aux_mod,
          name: peer,
          extra_config: extra_config,
          phoenix_port: TestEnv.peer_http_port(peer)
        )

      for _ <- 1..processes do
        pid = Rpc.call(node, Aux, :ping, [])

        for _ <- 1..10 do
          # replicate same pid added multiple times concurrently
          Task.start(fn ->
            Rpc.call(node, Aux, :join, [pid, tenant_id])
          end)

          # noisy neighbors to test handling of bigger loads on concurrent calls
          Task.start(fn ->
            Rpc.call(node, Aux, :join, [pid, random_string()])
          end)
        end
      end
    end)

    3 * processes
  end
end
