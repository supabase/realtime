defmodule TestEnvTest do
  # async: false — the run tag tests swap :realtime app env that Clustered and TestTenantDb
  # read while tests run.
  use ExUnit.Case, async: false

  defp put_node_suffix(suffix) do
    original = Application.fetch_env!(:realtime, :test_node_suffix)
    Application.put_env(:realtime, :test_node_suffix, suffix)
    on_exit(fn -> Application.put_env(:realtime, :test_node_suffix, original) end)
  end

  describe "node_name/0 and peer names" do
    test "the first run on a machine looks exactly like it did before run tags existed" do
      put_node_suffix("")

      assert TestEnv.node_name() == :"main@127.0.0.1"
      assert TestEnv.peer_name(:us_node) == :us_node
      assert TestEnv.peer_node(:us_node) == :"us_node@127.0.0.1"
    end

    test "a second run tags its node and its peers with its endpoint port" do
      put_node_suffix("_4003")

      assert TestEnv.node_name() == :"main_4003@127.0.0.1"
      assert TestEnv.peer_name(:us_node) == :us_node_4003
      assert TestEnv.peer_node(:us_node) == :"us_node_4003@127.0.0.1"
    end

    test "peers stay sorted around the local node name so syn conflict resolution is stable" do
      put_node_suffix("_4003")

      assert TestEnv.peer_node(:atest) < TestEnv.node_name()
      assert TestEnv.peer_node(:test) > TestEnv.node_name()
    end
  end

  describe "peer_http_port/1 and peer_gen_rpc_port/1" do
    test "a peer keeps one slot in both port ranges" do
      assert TestEnv.peer_http_port(:ap2_nodeX) - TestEnv.peer_http_port() ==
               TestEnv.peer_gen_rpc_port(:ap2_nodeX) - TestEnv.peer_gen_rpc_port()
    end

    test "every peer owns a distinct port" do
      http = Enum.map(TestEnv.peers(), &TestEnv.peer_http_port/1)
      gen_rpc = Enum.map(TestEnv.peers(), &TestEnv.peer_gen_rpc_port/1)

      assert length(Enum.uniq(http)) == length(TestEnv.peers())
      assert length(Enum.uniq(gen_rpc)) == length(TestEnv.peers())
      assert Enum.empty?(MapSet.intersection(MapSet.new(http), MapSet.new(gen_rpc)))
    end

    test "the ports this run claimed are the ones it hands out" do
      assert TestEnv.peer_http_port() == Application.fetch_env!(:realtime, :test_peer_http_base)
      assert TestEnv.peer_gen_rpc_port() == Application.fetch_env!(:realtime, :test_peer_gen_rpc_base)
    end

    test "every peer fits in the band a run reserves" do
      assert length(TestEnv.peers()) <= Application.fetch_env!(:realtime, :test_peer_ports_per_run)
    end

    test "raise on an unregistered peer" do
      assert_raise ArgumentError, ~r/unknown peer :nope/, fn -> TestEnv.peer_http_port(:nope) end
      assert_raise ArgumentError, ~r/unknown peer :nope/, fn -> TestEnv.peer_gen_rpc_port(:nope) end
    end
  end

  describe "port_available?/1" do
    test "true for a port nothing is listening on" do
      assert TestEnv.port_available?(TestEnv.unused_port())
    end

    test "false while a listener holds the port" do
      {:ok, socket} = :gen_tcp.listen(0, [:inet, ip: {0, 0, 0, 0}, reuseaddr: true, active: false])
      {:ok, port} = :inet.port(socket)
      on_exit(fn -> :gen_tcp.close(socket) end)

      refute TestEnv.port_available?(port)
    end

    test "the endpoint port this run claimed is held by this run" do
      refute TestEnv.port_available?(TestEnv.http_port())
    end
  end
end
