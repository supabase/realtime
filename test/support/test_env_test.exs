defmodule TestEnvTest do
  # async: false — these tests mutate the env vars TestEnv reads, and Clustered
  # and TestTenantDb read the same vars while tests run.
  use ExUnit.Case, async: false

  alias TestTenantDb.Backend.Docker

  @envs ~w(MIX_TEST_PARTITION TEST_NODE_SUFFIX TEST_PEER_PORT_BASE TEST_PEER_GEN_RPC_PORT_BASE
           TEST_TENANT_DB_PORT_RANGE TEST_CONTAINER_PREFIX)

  setup do
    original = Map.new(@envs, fn name -> {name, System.get_env(name)} end)
    Enum.each(@envs, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  describe "node_name/0" do
    test "defaults to main@127.0.0.1" do
      assert TestEnv.node_name() == :"main@127.0.0.1"
    end

    test "includes the test partition and the node suffix" do
      System.put_env("MIX_TEST_PARTITION", "2")
      System.put_env("TEST_NODE_SUFFIX", "7")

      assert TestEnv.node_name() == :"main2_7@127.0.0.1"
    end
  end

  describe "peer_name/1 and peer_node/1" do
    test "keep the given name when no suffix is set" do
      assert TestEnv.peer_name(:us_node) == :us_node
      assert TestEnv.peer_node(:us_node) == :"us_node@127.0.0.1"
    end

    test "append the node suffix" do
      System.put_env("TEST_NODE_SUFFIX", "7")

      assert TestEnv.peer_name(:us_node) == :us_node_7
      assert TestEnv.peer_node(:us_node) == :"us_node_7@127.0.0.1"
    end

    test "keep peers sorted around the local node name so syn conflict resolution is stable" do
      System.put_env("TEST_NODE_SUFFIX", "7")

      assert TestEnv.peer_node(:atest) < TestEnv.node_name()
      assert TestEnv.peer_node(:test) > TestEnv.node_name()
    end
  end

  describe "peer_http_port/1 and peer_gen_rpc_port/1" do
    test "default to the base of each block" do
      assert TestEnv.peer_http_port() == 4012
      assert TestEnv.peer_gen_rpc_port() == 16_970
    end

    test "a peer keeps one slot in both blocks" do
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

    test "shift with the configured bases" do
      System.put_env("TEST_PEER_PORT_BASE", "24012")
      System.put_env("TEST_PEER_GEN_RPC_PORT_BASE", "26970")

      assert TestEnv.peer_http_port(:us_node) == 24_013
      assert TestEnv.peer_gen_rpc_port(:us_node) == 26_971
    end

    test "raise on an unregistered peer" do
      assert_raise ArgumentError, ~r/unknown peer :nope/, fn -> TestEnv.peer_http_port(:nope) end
      assert_raise ArgumentError, ~r/unknown peer :nope/, fn -> TestEnv.peer_gen_rpc_port(:nope) end
    end
  end

  describe "tenant_db_port_range/0" do
    test "defaults to 6500..9000" do
      assert TestEnv.tenant_db_port_range() == 6500..9000
    end

    test "parses the configured range" do
      System.put_env("TEST_TENANT_DB_PORT_RANGE", "7000 - 7100")

      assert TestEnv.tenant_db_port_range() == 7000..7100
    end

    test "raises when the range is not two ports" do
      System.put_env("TEST_TENANT_DB_PORT_RANGE", "7000")

      assert_raise ArgumentError, fn -> TestEnv.tenant_db_port_range() end
    end

    test "raises when the range is inverted" do
      System.put_env("TEST_TENANT_DB_PORT_RANGE", "9000-6500")

      assert_raise ArgumentError, fn -> TestEnv.tenant_db_port_range() end
    end
  end

  describe "port_available?/1" do
    test "true for a port nothing is listening on" do
      {:ok, socket} = :gen_tcp.listen(0, [:inet, ip: {0, 0, 0, 0}, reuseaddr: true, active: false])
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)

      assert TestEnv.port_available?(port)
    end

    test "false while a listener holds the port" do
      {:ok, socket} = :gen_tcp.listen(0, [:inet, ip: {0, 0, 0, 0}, reuseaddr: true, active: false])
      {:ok, port} = :inet.port(socket)
      on_exit(fn -> :gen_tcp.close(socket) end)

      refute TestEnv.port_available?(port)
    end
  end

  describe "container naming" do
    test "container_name/0 uses the configured prefix" do
      System.put_env("TEST_CONTAINER_PREFIX", "realtime-test-7-")

      name = Docker.container_name()

      assert String.starts_with?(name, "realtime-test-7-")
      assert byte_size(name) == byte_size("realtime-test-7-") + TestEnv.container_suffix_length()
      assert Docker.own_container?(name)
    end

    test "own_container?/1 ignores containers from another prefix" do
      suffix = String.duplicate("a", TestEnv.container_suffix_length())

      assert Docker.own_container?("realtime-test-" <> suffix)
      refute Docker.own_container?("realtime-test-7-" <> suffix)
      refute Docker.own_container?("some-other-container")
    end
  end
end
