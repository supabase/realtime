# Run with:
#   MIX_ENV=test mix run --no-start bench/fanout_throughput.exs
#
# Local loopback scenario benchmark comparing per-node RPC fan-out with a
# single :syn process-group publish. This intentionally uses a custom timer
# instead of Benchee because each scenario needs distributed setup, delivery
# verification, and peer cleanup.

Application.ensure_all_started(:syn)
:logger.set_primary_config(:level, :warning)

node_count = 20
message_count = 500
scope = :bench_fanout
group = "fanout"

ensure_net_kernel! = fn ->
  node_name = :"main@127.0.0.1"

  case :net_kernel.start([node_name]) do
    {:ok, _} -> :ok
    {:error, {:already_started, _}} -> :ok
    {:error, reason} -> raise "Failed to start net_kernel: #{inspect(reason)}"
  end

  true = :erlang.set_cookie(:cookie)
end

start_peer = fn ->
  {:ok, pid, node} =
    :peer.start_link(%{
      name: :peer.random_name(),
      host: ~c"127.0.0.1",
      longnames: true,
      connection: :standard_io
    })

  true = :peer.call(pid, :erlang, :set_cookie, [:cookie])
  :ok = :peer.call(pid, :code, :add_paths, [:code.get_path()])
  :peer.call(pid, :logger, :set_primary_config, [:level, :warning])
  {:ok, _} = :peer.call(pid, Application, :ensure_all_started, [:syn])

  {pid, node}
end

start_rpc_counter = fn node ->
  {{pid, nil}, _} =
    :rpc.call(node, Code, :eval_quoted, [
      quote do
        pid =
          spawn(fn ->
            loop = fn count, loop ->
              receive do
                :ping ->
                  loop.(count + 1, loop)

                {:count, reply_to} ->
                  send(reply_to, count)
                  loop.(count, loop)
              after
                10_000 -> loop.(count, loop)
              end
            end

            loop.(0, loop)
          end)

        {pid, nil}
      end
    ])

  pid
end

start_syn_relay = fn {peer_pid, _node} ->
  {{counter_pid, _relay_pid}, _} =
    :peer.call(peer_pid, Code, :eval_quoted, [
      quote do
        scope = unquote(scope)
        group = unquote(group)

        counter =
          spawn(fn ->
            loop = fn count, loop ->
              receive do
                :inc ->
                  loop.(count + 1, loop)

                {:count, reply_to} ->
                  send(reply_to, count)
                  loop.(count, loop)
              after
                10_000 -> loop.(count, loop)
              end
            end

            loop.(0, loop)
          end)

        relay =
          spawn(fn ->
            :ok = :syn.add_node_to_scopes([scope])
            :ok = :syn.join(scope, group, self())

            loop = fn loop ->
              receive do
                :ping ->
                  send(counter, :inc)
                  loop.(loop)
              after
                10_000 -> loop.(loop)
              end
            end

            loop.(loop)
          end)

        {counter, relay}
      end
    ])

  counter_pid
end

wait_for_syn_members = fn ->
  Enum.reduce_while(1..100, nil, fn _, _ ->
    case :syn.member_count(scope, group) do
      count when count == node_count ->
        {:halt, :ok}

      _ ->
        Process.sleep(50)
        {:cont, nil}
    end
  end)
end

ensure_net_kernel!.()
peers = for _ <- 1..node_count, do: start_peer.()
nodes = Enum.map(peers, fn {_pid, node} -> node end)

try do
  IO.puts("Started #{node_count} peer nodes\n")

  true = Node.connect(hd(nodes))
  Process.sleep(100)

  rpc_counter_pids = Enum.map(nodes, start_rpc_counter)
  Process.sleep(200)

  {rpc_us, _} =
    :timer.tc(fn ->
      for _ <- 1..message_count,
          {node, counter_pid} <- Enum.zip(nodes, rpc_counter_pids) do
        true = :rpc.cast(node, Kernel, :send, [counter_pid, :ping])
      end
    end)

  Process.sleep(1000)

  Enum.zip(nodes, rpc_counter_pids)
  |> Enum.each(fn {node, counter_pid} ->
    :rpc.cast(node, Kernel, :send, [counter_pid, {:count, self()}])

    receive do
      count when count == message_count -> :ok
      other -> raise "RPC peer #{node} got #{other} messages, expected #{message_count}"
    after
      1000 -> raise "RPC counter timeout"
    end
  end)

  rpc_ms = rpc_us / 1000

  IO.puts("RPC broadcast:")
  IO.puts("  total send time: #{Float.round(rpc_ms, 2)} ms")
  IO.puts("  sends/sec:       #{Float.round(message_count * 1000 / rpc_ms, 2)}")
  IO.puts("  per node:        #{Float.round(rpc_ms / node_count, 3)} ms")

  :ok = :syn.add_node_to_scopes([scope])
  syn_counter_pids = Enum.map(peers, start_syn_relay)
  wait_for_syn_members.()
  Process.sleep(500)

  {:ok, warmup_count} = :syn.publish(scope, group, :ping)
  IO.puts("  syn fanout group ready: #{warmup_count} relay(s)")
  Process.sleep(200)

  {syn_us, _} =
    :timer.tc(fn ->
      for _ <- 1..message_count do
        {:ok, ^node_count} = :syn.publish(scope, group, :ping)
      end
    end)

  Process.sleep(1000)

  Enum.zip(peers, syn_counter_pids)
  |> Enum.each(fn {{peer_pid, node}, counter_pid} ->
    :peer.call(peer_pid, Kernel, :send, [counter_pid, {:count, self()}])

    receive do
      count when count == message_count + 1 -> :ok
      other -> raise "Syn peer #{node} got #{other} messages, expected #{message_count + 1}"
    after
      1000 -> raise "Syn counter timeout"
    end
  end)

  syn_ms = syn_us / 1000

  IO.puts("\nSyn broadcast:")
  IO.puts("  total send time: #{Float.round(syn_ms, 2)} ms")
  IO.puts("  sends/sec:       #{Float.round(message_count * 1000 / syn_ms, 2)}")
  IO.puts("  per node:        #{Float.round(syn_ms / node_count, 3)} ms")

  IO.puts("\n=== Summary ===")
  IO.puts("Nodes:           #{node_count}")
  IO.puts("Messages:        #{message_count}")
  IO.puts("RPC total time:  #{Float.round(rpc_ms, 2)} ms")
  IO.puts("Syn total time:  #{Float.round(syn_ms, 2)} ms")
  IO.puts("Speedup:         #{Float.round(rpc_ms / syn_ms, 2)}x")
after
  Enum.each(peers, fn {pid, _node} -> :peer.stop(pid) end)
end
