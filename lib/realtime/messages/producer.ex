defmodule Realtime.Messages.Producer do
  @moduledoc """
  The producer stage of the pipeline that persists messages for one tenant database connection, see
  "Persistence" in `Realtime.Messages`.

  It buffers messages in its own queue and buffers the consumer's demand as `pending_demand`, as described
  in "Buffering demand" in `GenStage`. Each event is a batch of the oldest messages, up to
  `:max_batch_size` messages and `:max_batch_bytes`. While there is pending demand, a batch is emitted as
  soon as it is full, and otherwise once `:flush_interval_ms` passed since the previous one.

  A message is rejected when `:max_pending` messages or `:max_pending_bytes` are queued or being written.
  A `:reply_to` gets the result once the message is written. Senders on other nodes reach it through
  `Realtime.Messages.Router`, which sends to it without waiting, and get their errors at their `:reply_to`.

  The producer logs the messages that were not persisted, its own and the ones the consumer reports, once
  per reason every `:drops_report_interval_ms`.

  The producer starts `Realtime.Messages.Consumer`, linked, which subscribes to it, and stops
  when it stops. On shutdown, the consumer writes the messages still queued after the events it was sent.
  Messages sent to the producer while it stops fail with `persistence_unavailable`.

  Both stages use `Realtime.Messages.config/0`, with the `:config` option merged over it.
  """
  use GenStage

  alias Realtime.Messages
  alias Realtime.Messages.Consumer

  def child_spec(opts) do
    opts = Keyword.update(opts, :config, Messages.config(), &Keyword.merge(Messages.config(), &1))

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: opts[:config][:query_timeout] + 1_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = {:via, Registry, {Realtime.Registry.Unique, {__MODULE__, Keyword.fetch!(opts, :db_conn)}}}
    GenStage.start_link(__MODULE__, opts, name: name, hibernate_after: Keyword.fetch!(opts, :config)[:hibernate_after])
  end

  @impl true
  def init(opts) do
    db_conn = Keyword.fetch!(opts, :db_conn)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    config = Keyword.fetch!(opts, :config)

    # Queued messages must be written on shutdown, or failed when the consumer crashes
    Process.flag(:trap_exit, true)
    # The pipeline serves one connection and stops with it
    Process.monitor(db_conn)
    Logger.metadata(external_id: tenant_id, project: tenant_id)
    {:ok, consumer} = Consumer.start_link(Keyword.put(opts, :producer, self()))

    {:producer,
     %{
       db_conn: db_conn,
       tenant_id: tenant_id,
       config: config,
       consumer: consumer,
       queue: :queue.new(),
       count: 0,
       bytes: 0,
       writing: {0, 0},
       pending_demand: 0,
       timer: nil,
       emitted_at: System.monotonic_time(:millisecond) - config[:flush_interval_ms],
       drops: %{}
     }}
  end

  @doc """
  Queues a message from `Realtime.Messages.persist/6`, which persists for senders on the node of the
  connection. It replies `:ok` once the message is admitted, without waiting for the write, or the
  rejection. The message's `:reply_to` gets the result once it is written.
  """
  @impl true
  def handle_call({:persist, entry, caller}, from, state) do
    case admit(state, entry) do
      :ok ->
        GenStage.reply(from, :ok)
        state |> enqueue(entry, caller) |> dispatch_events()

      {:error, reason} = error ->
        {:reply, error, [], drop(state, reason, 1)}
    end
  end

  @impl true
  def handle_demand(incoming_demand, state) do
    dispatch_events(%{state | pending_demand: state.pending_demand + incoming_demand, writing: {0, 0}})
  end

  @doc """
  Queues a `{:persist, entry, caller}` message sent by `Realtime.Messages.enqueue/4`, which persists for
  senders on other nodes without waiting on the producer. It admits the message like `handle_call/3`, but
  sends a rejection to the message's `:reply_to`, since nobody waits for a reply. The other clauses handle
  the producer's timers and the exits of the connection and the consumer.
  """
  @impl true
  def handle_info({:persist, entry, caller}, state) do
    case admit(state, entry) do
      :ok ->
        state |> enqueue(entry, caller) |> dispatch_events()

      {:error, reason} = error ->
        Messages.reply([{caller, error}])
        {:noreply, [], drop(state, reason, 1)}
    end
  end

  def handle_info(:flush, state), do: dispatch_events(%{state | timer: nil})
  def handle_info({:dropped, reason, count}, state), do: {:noreply, [], drop(state, reason, count)}
  def handle_info(:report_drops, state), do: {:noreply, [], report_drops(state)}

  def handle_info({:DOWN, _ref, :process, db_conn, _reason}, %{db_conn: db_conn} = state) do
    {:stop, :normal, fail_queued(state, :persistence_unavailable)}
  end

  def handle_info({:EXIT, consumer, reason}, %{consumer: consumer} = state) do
    {:stop, reason, %{state | consumer: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, [], state}

  @impl true
  def terminate(_reason, %{consumer: nil} = state) do
    state |> fail_queued(:persistence_unavailable) |> fail_unread() |> receive_drops() |> report_drops()
  end

  def terminate(_reason, state) do
    stop_consumer(state)
    state |> fail_unread() |> receive_drops() |> report_drops()
  end

  defp admit(state, entry) do
    {writing_count, writing_bytes} = state.writing

    cond do
      state.count + writing_count >= state.config[:max_pending] -> {:error, :persistence_buffer_full}
      state.bytes + writing_bytes + entry.bytes > state.config[:max_pending_bytes] -> {:error, :persistence_buffer_full}
      true -> :ok
    end
  end

  defp enqueue(state, entry, caller) do
    %{state | queue: :queue.in({entry, caller}, state.queue), count: state.count + 1, bytes: state.bytes + entry.bytes}
  end

  defp dispatch_events(%{pending_demand: 0} = state), do: {:noreply, [], state}
  defp dispatch_events(%{count: 0} = state), do: {:noreply, [], state}

  defp dispatch_events(state) do
    wait = state.emitted_at + state.config[:flush_interval_ms] - System.monotonic_time(:millisecond)

    cond do
      full?(state) or wait <= 0 -> emit(state)
      state.timer -> {:noreply, [], state}
      true -> {:noreply, [], %{state | timer: Process.send_after(self(), :flush, wait)}}
    end
  end

  defp full?(state) do
    state.count >= state.config[:max_batch_size] or state.bytes >= state.config[:max_batch_bytes]
  end

  defp emit(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {batch, rest} = take(state)
    writing = {state.count - rest.count, state.bytes - rest.bytes}
    now = System.monotonic_time(:millisecond)

    {:noreply, [batch],
     %{rest | pending_demand: rest.pending_demand - 1, timer: nil, emitted_at: now, writing: writing}}
  end

  # Takes the oldest messages, at least one, up to `:max_batch_size` messages and `:max_batch_bytes`
  defp take(state) do
    {batch, queue, count, bytes} =
      take(state.queue, state.config[:max_batch_size], state.config[:max_batch_bytes], [], 0, 0)

    {batch, %{state | queue: queue, count: state.count - count, bytes: state.bytes - bytes}}
  end

  defp take(queue, max_count, max_bytes, batch, count, bytes) do
    with {:value, {entry, _caller} = item} <- :queue.peek(queue),
         true <- count == 0 or (count < max_count and bytes + entry.bytes <= max_bytes) do
      take(:queue.drop(queue), max_count, max_bytes, [item | batch], count + 1, bytes + entry.bytes)
    else
      _ -> {Enum.reverse(batch), queue, count, bytes}
    end
  end

  defp batches(%{count: 0}), do: []

  defp batches(state) do
    {batch, state} = take(state)
    [batch | batches(state)]
  end

  # The consumer writes the queued messages after the events it was sent, so they keep their order
  defp stop_consumer(state) do
    GenStage.call(state.consumer, {:stop, batches(state)}, :infinity)
  catch
    :exit, _ -> :ok
  end

  defp fail_queued(state, reason) do
    queued = :queue.to_list(state.queue)
    Messages.reply(for {_entry, caller} <- queued, do: {caller, {:error, reason}})
    drop(%{state | queue: :queue.new(), count: 0, bytes: 0}, reason, length(queued))
  end

  # It stays registered until it exits, so senders on other nodes keep sending to it while it stops. Senders
  # on this node call it, and get `persistence_unavailable` when it exits
  defp fail_unread(state) do
    receive do
      {:persist, _entry, caller} ->
        Messages.reply([{caller, {:error, :persistence_unavailable}}])
        state |> drop(:persistence_unavailable, 1) |> fail_unread()
    after
      0 -> state
    end
  end

  defp drop(state, _reason, 0), do: state

  defp drop(state, reason, count) do
    Messages.emit_dropped(state.tenant_id, reason, count)
    if state.drops == %{}, do: Process.send_after(self(), :report_drops, state.config[:drops_report_interval_ms])
    %{state | drops: Map.update(state.drops, reason, count, &(&1 + count))}
  end

  defp receive_drops(state) do
    receive do
      {:dropped, reason, count} -> state |> drop(reason, count) |> receive_drops()
    after
      0 -> state
    end
  end

  defp report_drops(state) do
    Enum.each(state.drops, fn {reason, count} ->
      code = if reason == :persistence_buffer_full, do: "PersistenceLimitReached", else: "UnableToPersistMessage"
      Messages.log_dropped(code, reason, count)
    end)

    %{state | drops: %{}}
  end
end
