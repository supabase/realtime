# Run with:
#   MIX_ENV=test mix run --no-start bench/multi_node_syn.exs
#
# Local loopback benchmark comparing single-peer :rpc calls/casts with :syn
# process-group publish. Roundtrips use a small manual timer; fire-and-forget
# paths use Benchee like the existing benchmarks in this directory.

Application.ensure_all_started(:syn)
:logger.set_primary_config(:level, :warning)

roundtrips = 100
scope = :bench_multi_node
group = "echo"

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

  {:ok, pid, node}
end

wait_for_relay = fn ->
  Enum.reduce_while(1..100, nil, fn _, _ ->
    case :syn.member_count(scope, group) do
      1 ->
        {:halt, :ok}

      _ ->
        Process.sleep(50)
        {:cont, nil}
    end
  end)
end

start_echo_relay = fn peer_pid ->
  :peer.call(peer_pid, Code, :eval_quoted, [
    quote do
      scope = unquote(scope)
      group = unquote(group)

      spawn(fn ->
        :ok = :syn.add_node_to_scopes([scope])
        :ok = :syn.join(scope, group, self())

        loop = fn loop ->
          receive do
            {:echo, payload, reply_to} ->
              send(reply_to, {:echo_reply, payload})
              loop.(loop)
          after
            5000 -> loop.(loop)
          end
        end

        loop.(loop)
      end)

      :ok
    end
  ])
end

measure_rpc_roundtrip = fn node ->
  {rpc_rt_us, _} =
    :timer.tc(fn ->
      for _ <- 1..roundtrips do
        :pong = :rpc.call(node, Kernel, :send, [self(), :pong], 5000)

        receive do
          :pong -> :ok
        after
          2000 -> raise "timeout"
        end
      end
    end)

  IO.puts("\nrpc call roundtrip: #{roundtrips} roundtrips in #{rpc_rt_us} μs")
  IO.puts("  average: #{Float.round(rpc_rt_us / roundtrips, 2)} μs")
  IO.puts("  ips:     #{Float.round(roundtrips * 1_000_000 / rpc_rt_us, 2)}")
end

measure_syn_roundtrip = fn ->
  :ok = :syn.join(scope, "replies", self())

  {:ok, recipient_count} = :syn.publish(scope, group, {:echo, :warmup, self()})
  IO.puts("  syn warmup publish recipients: #{recipient_count}")

  receive do
    {:echo_reply, :warmup} -> :ok
  after
    10_000 -> raise "warmup timeout"
  end

  {syn_rt_us, _} =
    :timer.tc(fn ->
      for i <- 1..roundtrips do
        {:ok, _} = :syn.publish(scope, group, {:echo, i, self()})

        receive do
          {:echo_reply, ^i} -> :ok
        after
          2000 -> raise "timeout"
        end
      end
    end)

  IO.puts("\nsyn roundtrip: #{roundtrips} roundtrips in #{syn_rt_us} μs")
  IO.puts("  average: #{Float.round(syn_rt_us / roundtrips, 2)} μs")
  IO.puts("  ips:     #{Float.round(roundtrips * 1_000_000 / syn_rt_us, 2)}")

  :ok = :syn.leave(scope, "replies", self())
end

ensure_net_kernel!.()
{:ok, peer_pid, node} = start_peer.()

try do
  IO.puts("Peer node started: #{node}")

  :ok = :syn.add_node_to_scopes([scope])
  _ = start_echo_relay.(peer_pid)

  true = Node.connect(node)
  wait_for_relay.()
  Process.sleep(500)

  measure_rpc_roundtrip.(node)

  rpc_drain_pid =
    spawn(fn ->
      loop = fn loop ->
        receive do
          :ping -> loop.(loop)
        after
          5000 -> loop.(loop)
        end
      end

      loop.(loop)
    end)

  Benchee.run(
    %{
      "rpc cast fire-and-forget" => fn ->
        true = :rpc.cast(node, Kernel, :send, [rpc_drain_pid, :ping])
        :ok
      end
    },
    warmup: 1,
    time: 5
  )

  Process.exit(rpc_drain_pid, :kill)

  measure_syn_roundtrip.()

  {syn_drain_pid, _} =
    :peer.call(peer_pid, Code, :eval_quoted, [
      quote do
        spawn(fn ->
          loop = fn loop ->
            receive do
              :ping -> loop.(loop)
            after
              5000 -> loop.(loop)
            end
          end

          loop.(loop)
        end)
      end
    ])

  Benchee.run(
    %{
      "syn publish fire-and-forget" => fn ->
        {:ok, _} = :syn.publish(scope, group, {:echo, :ping, syn_drain_pid})
        :ok
      end
    },
    warmup: 1,
    time: 5
  )
after
  :peer.stop(peer_pid)
end
