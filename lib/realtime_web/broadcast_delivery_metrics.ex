defmodule RealtimeWeb.BroadcastDeliveryMetrics do
  @moduledoc """
  Time to hand a tenant broadcast to the subscriber sockets on this node.

  `with_timing/3` runs the local dispatch with a clock in the process dictionary. The dispatcher
  runs in that process and sends to sockets with `send_push/2`, which stamps the time of each
  send. When the dispatch returns and at least one socket was sent the message, one sample is
  recorded: the time from the start of the local dispatch to the last send.

  The clock starts after the message has been routed to the other nodes, and each node that
  receives it starts its own clock when it dispatches it, so the clock never crosses nodes.
  Samples are tagged `origin: :local` on the node where the message was published and
  `origin: :remote` on the nodes that received it. Not included: the hop between nodes, the wait
  in the receiving worker's mailbox, the wait in the socket's mailbox and the socket write. No
  sample is recorded when the dispatch raises or no socket was sent the message.
  """
  @event [:realtime, :broadcast, :delivery, :latency]
  @key {__MODULE__, :timing}

  @type origin :: :local | :remote

  @spec event() :: [atom()]
  def event, do: @event

  @doc "Runs a local dispatch with the clock started and records a sample if a socket was sent to."
  @spec with_timing(String.t(), origin(), (-> result)) :: result when result: term()
  def with_timing(tenant_id, origin, fun) do
    previous = Process.put(@key, {tenant_id, origin, System.monotonic_time(), nil})

    try do
      fun.()
    else
      result ->
        timing = Process.get(@key)
        restore(previous)
        record(timing)
        result
    after
      restore(previous)
    end
  end

  @doc "Sends an encoded push to a socket, stamping the running clock if there is one."
  @spec send_push(pid(), push) :: push when push: term()
  def send_push(transport_pid, push) do
    case Process.get(@key) do
      {tenant_id, origin, started_at, _} ->
        Process.put(@key, {tenant_id, origin, started_at, System.monotonic_time()})

      nil ->
        :ok
    end

    send(transport_pid, push)
  end

  defp restore(nil), do: Process.delete(@key)
  defp restore(previous), do: Process.put(@key, previous)

  defp record({_tenant_id, _origin, _started_at, nil}), do: :ok

  defp record({tenant_id, origin, started_at, last_sent_at}) do
    :telemetry.execute(@event, %{latency: last_sent_at - started_at}, %{tenant: tenant_id, origin: origin})
  end
end
