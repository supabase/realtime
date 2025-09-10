Application.put_env(:phoenix_pubsub, :test_adapter, {Realtime.GenRpcPubSub, []})

# Original: https://github.com/phoenixframework/phoenix_pubsub/blob/v2.1.3/test/shared/pubsub_test.exs
# We are copying this test from phoenix_pubsub because we don't want to run this
# test case "async: true" as it conflicts with the running pub sub adapter
# We also need to reset the persitent_term.
defmodule Phoenix.PubSubTest do
  @moduledoc """
  Sets up PubSub Adapter testcases.

  ## Usage

  To test a PubSub adapter, set the `:test_adapter` on the `:phoenix_pubsub`
  configuration and require this file, ie:

      # your_pubsub_adapter_test.exs
      Application.put_env(:phoenix_pubsub, :test_adapter, {Phoenix.PubSub.PG2, []})
      Code.require_file "../deps/phoenix_pubsub/test/shared/pubsub_test.exs", __DIR__

  """

  use ExUnit.Case, async: false
  alias Phoenix.PubSub

  # Reset the persistent term that GenRpc adapter uses
  setup_all do
    previous = :persistent_term.get(:gen_rpc)
    on_exit(fn -> :persistent_term.put(:gen_rpc, previous) end)
    :ok
  end

  defp subscribers(config, topic) do
    Registry.lookup(config.pubsub, topic)
  end

  defp rpc(pid, func) do
    Agent.get(pid, fn :ok -> func.() end)
  end

  defp spawn_pid do
    {:ok, pid} = Agent.start_link(fn -> :ok end)
    pid
  end

  defmodule CustomDispatcher do
    def dispatch(entries, from, message) do
      for {pid, metadata} <- entries do
        send(pid, {:custom, metadata, from, message})
      end

      :ok
    end
  end

  setup config do
    size = config[:pool_size] || 1
    {adapter, adapter_opts} = Application.get_env(:phoenix_pubsub, :test_adapter)
    adapter_opts = [adapter: adapter, name: config.test, pool_size: size] ++ adapter_opts
    start_supervised!({Phoenix.PubSub, adapter_opts})

    opts = %{
      pubsub: config.test,
      topic: to_string(config.test),
      pool_size: size,
      node: Phoenix.PubSub.node_name(config.test)
    }

    {:ok, opts}
  end

  test "node_name/1 returns the node name", config do
    assert is_atom(config.node) or is_binary(config.node)
  end

  for size <- [1, 8] do
    @tag pool_size: size
    test "pool #{size}: subscribe and unsubscribe", config do
      pid = spawn_pid()
      assert subscribers(config, config.topic) |> length == 0
      assert rpc(pid, fn -> PubSub.subscribe(config.pubsub, config.topic) end)
      assert subscribers(config, config.topic) == [{pid, nil}]
      assert rpc(pid, fn -> PubSub.unsubscribe(config.pubsub, config.topic) end)
      assert subscribers(config, config.topic) |> length == 0
    end

    @tag pool_size: size
    test "pool #{size}: broadcast/3 and broadcast!/3 publishes message to each subscriber",
         config do
      PubSub.subscribe(config.pubsub, config.topic)
      :ok = PubSub.broadcast(config.pubsub, config.topic, :ping)
      assert_receive :ping
      :ok = PubSub.broadcast!(config.pubsub, config.topic, :ping)
      assert_receive :ping
    end

    @tag pool_size: size
    test "pool #{size}: broadcast/3 does not publish message to other topic subscribers",
         config do
      PubSub.subscribe(config.pubsub, "unknown")

      Enum.each(0..10, fn _ ->
        rpc(spawn_pid(), fn -> PubSub.subscribe(config.pubsub, config.topic) end)
      end)

      :ok = PubSub.broadcast(config.pubsub, config.topic, :ping)
      refute_received :ping
    end

    @tag pool_size: size
    test "pool #{size}: broadcast_from/4 and broadcast_from!/4 skips sender", config do
      PubSub.subscribe(config.pubsub, config.topic)

      PubSub.broadcast_from(config.pubsub, self(), config.topic, :ping)
      refute_received :ping

      PubSub.broadcast_from!(config.pubsub, self(), config.topic, :ping)
      refute_received :ping
    end

    @tag pool_size: size
    test "pool #{size}: unsubscribe on not subscribed topic noops", config do
      assert :ok = PubSub.unsubscribe(config.pubsub, config.topic)
      assert subscribers(config, config.topic) == []
    end

    @tag pool_size: size
    test "pool #{size}: direct_broadcast sends to given node", config do
      PubSub.subscribe(config.pubsub, config.topic)

      PubSub.direct_broadcast(config.node, config.pubsub, config.topic, :ping)
      assert_receive :ping

      PubSub.direct_broadcast!(config.node, config.pubsub, config.topic, :ping)
      assert_receive :ping
    end

    @tag pool_size: size
    test "pool #{size}: direct_broadcast sends to unknown node", config do
      PubSub.subscribe(config.pubsub, config.topic)

      PubSub.direct_broadcast(:"IDONTKNOW@127.0.0.1", config.pubsub, config.topic, :ping)
      refute_received :ping

      PubSub.direct_broadcast!(:"IDONTKNOW@127.0.0.1", config.pubsub, config.topic, :ping)
      refute_received :ping
    end

    @tag pool_size: size
    test "pool #{size}: local_broadcast sends to the current node", config do
      PubSub.subscribe(config.pubsub, config.topic)

      PubSub.local_broadcast(config.pubsub, config.topic, :ping)
      assert_receive :ping
    end

    @tag pool_size: size
    test "pool #{size}: local_broadcast_from/5 skips sender", config do
      PubSub.subscribe(config.pubsub, config.topic)

      PubSub.local_broadcast_from(config.pubsub, self(), config.topic, :ping)
      refute_received :ping
    end

    @tag pool_size: size
    test "pool #{size}: with custom dispatching", %{topic: topic, test: test, node: node} do
      PubSub.subscribe(test, topic)
      PubSub.subscribe(test, topic, metadata: :special)

      PubSub.broadcast(test, topic, :broadcast, CustomDispatcher)
      assert_receive {:custom, nil, :none, :broadcast}
      assert_receive {:custom, :special, :none, :broadcast}

      PubSub.broadcast_from(test, self(), topic, :broadcast_from, CustomDispatcher)
      assert_receive {:custom, nil, pid, :broadcast_from} when pid == self()
      assert_receive {:custom, :special, pid, :broadcast_from} when pid == self()

      PubSub.local_broadcast(test, topic, :local, CustomDispatcher)
      assert_receive {:custom, nil, :none, :local}
      assert_receive {:custom, :special, :none, :local}

      PubSub.local_broadcast_from(test, self(), topic, :local_from, CustomDispatcher)
      assert_receive {:custom, nil, pid, :local_from} when pid == self()
      assert_receive {:custom, :special, pid, :local_from} when pid == self()

      PubSub.direct_broadcast(node, test, topic, :direct, CustomDispatcher)
      assert_receive {:custom, nil, :none, :direct}
      assert_receive {:custom, :special, :none, :direct}
    end
  end
end
