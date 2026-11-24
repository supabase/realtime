# Same key, same gen_rpc client, same TCP socket, and `:gen_rpc.cast/4` still applies out of order.
#
# Links are to emqx/gen_rpc 4.0.3, the version in mix.lock.
#
# 1. The key keeps the wire order. A `{node, key}` destination is one client process, registered as
#    `{client, {node, key}}`, holding one socket:
#    https://github.com/emqx/gen_rpc/blob/15bcc58a1c480576b72fd6712865ccfca5c8e140/src/gen_rpc_client.erl#L531-L557
#    https://github.com/emqx/gen_rpc/blob/15bcc58a1c480576b72fd6712865ccfca5c8e140/src/gen_rpc_client.erl#L277-L278
#
# 2. The receiving acceptor reads them in that order and hands each to `exec_cast/4`, whose last argument,
#    `PreserveOrder`, is `false` for a cast and `true` for an ordered cast:
#    https://github.com/emqx/gen_rpc/blob/15bcc58a1c480576b72fd6712865ccfca5c8e140/src/gen_rpc_acceptor.erl#L140-L145
#
# 3. That's where the order is lost. `false` is a bare `erlang:spawn(M, F, A)`, and the acceptor moves on,
#    so the applies run concurrently on any scheduler and race. `true` is `spawn_monitor` plus a `receive`
#    for the `'DOWN'`, so the next apply starts only after this one returned:
#    https://github.com/emqx/gen_rpc/blob/15bcc58a1c480576b72fd6712865ccfca5c8e140/src/gen_rpc_acceptor.erl#L379-L386
#
# 4. gen_rpc says so itself: regular casts "can be executed in any order", and an ordered cast "will block
#    the entire queue" for that key while it runs, which is why its apply must return fast:
#    https://github.com/emqx/gen_rpc/blob/15bcc58a1c480576b72fd6712865ccfca5c8e140/src/gen_rpc.erl#L84-L87
#
# The script casts 1..10 with one key to a peer node, where each apply pushes its number to a `:queue`
# held by an Agent. A race doesn't lose on every run, so it repeats that up to 100 times and prints the
# first queue that came out of order, or the last one, for each kind of cast.
#
#   mix run --no-start dev/scripts/gen_rpc_cast_order.exs

defmodule GenRpcCastOrder do
  @moduledoc false

  @count 10
  @tries 100

  def main do
    Logger.configure(level: :warning)
    port = free_port()
    start_distribution()
    receiver = start_receiver(port)
    start_gen_rpc(port)

    for kind <- [:cast, :ordered_cast] do
      {result, items} = run(kind, receiver, 1)
      IO.puts("#{kind} (#{result}):\n#{inspect(items, limit: :infinity, charlists: :as_lists)}\n")
    end

    Application.stop(:gen_rpc)
  end

  defp run(kind, receiver, attempt) do
    items = cast_all(kind, receiver)

    cond do
      items != Enum.sort(items) -> {"out of order on try #{attempt}", items}
      attempt == @tries -> {"in order on all #{@tries} tries", items}
      true -> run(kind, receiver, attempt + 1)
    end
  end

  defp cast_all(kind, receiver) do
    {:ok, queue} = :erpc.call(receiver, Agent, :start, [:queue, :new, []])
    # One key, so one gen_rpc client
    destination = {receiver, kind}

    for i <- 1..@count do
      args = [queue, :queue, :snoc, [i]]

      case kind do
        :cast -> :gen_rpc.cast(destination, Agent, :cast, args)
        :ordered_cast -> :gen_rpc.ordered_cast(destination, Agent, :cast, args)
      end
    end

    items = all(receiver, queue)
    :ok = :erpc.call(receiver, Agent, :stop, [queue])
    items
  end

  # The casts return before the receiver applies them, so it waits until all of them are in the queue
  defp all(receiver, queue) do
    case :erpc.call(receiver, Agent, :get, [queue, :queue, :to_list, []]) do
      items when length(items) == @count -> items
      _ -> all(receiver, queue)
    end
  end

  defp start_distribution do
    unless Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _} = :net_kernel.start(:"gen_rpc_repro_sender@127.0.0.1", %{name_domain: :longnames})
    end

    :erlang.set_cookie(:gen_rpc_repro)
  end

  defp start_receiver(port) do
    {:ok, _peer, receiver} =
      :peer.start_link(%{
        name: :gen_rpc_repro_receiver,
        host: ~c"127.0.0.1",
        longnames: true,
        # Wakes idle schedulers as soon as there's work, as they're awake on a busy node, so the applies
        # spread over them like in production
        args: [~c"-setcookie", ~c"gen_rpc_repro", ~c"+swt", ~c"very_low"]
      })

    :ok = :erpc.call(receiver, :logger, :set_primary_config, [:level, :warning])
    :ok = :erpc.call(receiver, :code, :add_paths, [:code.get_path()])
    :ok = :erpc.call(receiver, :application, :load, [:gen_rpc])
    :ok = :erpc.call(receiver, :application, :set_env, [:gen_rpc, :tcp_server_port, port])
    {:ok, _} = :erpc.call(receiver, :application, :ensure_all_started, [:gen_rpc])
    receiver
  end

  # This node only sends, so it doesn't listen, and it dials the receiver on `port`
  defp start_gen_rpc(port) do
    _ = Application.load(:gen_rpc)
    Application.put_env(:gen_rpc, :tcp_server_port, false)
    Application.put_env(:gen_rpc, :tcp_client_port, port)
    Application.put_env(:gen_rpc, :client_config_per_node, {:internal, %{}})
    {:ok, _} = Application.ensure_all_started(:gen_rpc)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end

GenRpcCastOrder.main()
