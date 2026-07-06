defmodule Realtime.Broker.Syn do
  @moduledoc """
  `:syn` backed implementation of `Realtime.Broker`.

  Uses a single `:syn` process group per node as a fan-out relay.  Publishing a
  tenant message delivers it once to every node in the cluster via
  `:syn.publish/3`; the local relay on each node then performs a
  `Phoenix.PubSub.local_broadcast/4` so existing channel dispatchers keep working
  unchanged.

  This removes the per-node `gen_rpc` connections from the hot broadcast path
  and relies on `:syn`, which is already part of the Realtime supervision tree.
  """

  use GenServer
  use Realtime.Logs

  alias Realtime.Telemetry

  @behaviour Realtime.Broker

  @scope Realtime.Broker
  @fanout_group "fanout"
  @batch_event "__batch__"

  @default_pubsub Realtime.PubSub
  @default_flush_interval_ms 1
  @default_flush_max_size 100

  defstruct [:pubsub, :buffer, :timer, :flush_interval_ms, :flush_max_size]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @impl Realtime.Broker
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [Keyword.put_new(opts, :name, __MODULE__)]},
      type: :worker,
      restart: :permanent
    }
  end

  @impl Realtime.Broker
  def publish(topic, message, opts \\ []) do
    broker_pid = Keyword.get(opts, :broker_pid) || Process.whereis(__MODULE__)

    if broker_pid do
      GenServer.call(broker_pid, {:publish, topic, message, opts})
    else
      {:error, :broker_not_running}
    end
  end

  @impl Realtime.Broker
  def subscribe(topic, opts \\ []) do
    pubsub = Keyword.get(opts, :pubsub, @default_pubsub)
    Phoenix.PubSub.subscribe(pubsub, topic, opts)
  end

  @impl Realtime.Broker
  def unsubscribe(topic) do
    Phoenix.PubSub.unsubscribe(@default_pubsub, topic)
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:fullsweep_after, 20)

    pubsub = Keyword.get(opts, :pubsub, @default_pubsub)
    flush_interval_ms = Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms)
    flush_max_size = Keyword.get(opts, :flush_max_size, @default_flush_max_size)

    :ok = :syn.add_node_to_scopes([@scope])
    :ok = :syn.join(@scope, @fanout_group, self(), node: node())

    {:ok,
     %__MODULE__{
       pubsub: pubsub,
       buffer: %{},
       timer: nil,
       flush_interval_ms: flush_interval_ms,
       flush_max_size: flush_max_size
     }}
  end

  @impl true
  def handle_call({:publish, topic, message, opts}, _from, state) do
    dispatcher = Keyword.get(opts, :dispatcher)
    from = Keyword.get(opts, :from)
    payload = {topic, message, dispatcher, from}

    case :syn.publish(@scope, @fanout_group, payload) do
      {:ok, 0} ->
        # No relay has joined the fanout group yet.  Fall back to a local
        # broadcast so the caller does not silently drop messages during startup
        # or on a single-node deployment.
        do_local_broadcast(state.pubsub, topic, message, dispatcher, from)
        Telemetry.execute([:realtime, :broker, :syn, :publish], %{}, %{topic: topic, fallback: true})
        {:reply, :ok, state}

      {:ok, _count} ->
        Telemetry.execute([:realtime, :broker, :syn, :publish], %{}, %{topic: topic, fallback: false})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({topic, message, dispatcher, from}, state) do
    {state, flush?} = buffer_message(state, topic, message, dispatcher, from)

    if flush? do
      flush(state)
    else
      Telemetry.execute([:realtime, :broker, :syn, :receive], %{}, %{topic: topic})
      {:noreply, state}
    end
  end

  def handle_info(:flush, state) do
    flush(%{state | timer: nil})
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp do_local_broadcast(pubsub, topic, message, nil, nil) do
    Phoenix.PubSub.local_broadcast(pubsub, topic, message)
  end

  defp do_local_broadcast(pubsub, topic, message, dispatcher, nil) do
    Phoenix.PubSub.local_broadcast(pubsub, topic, message, dispatcher)
  end

  defp do_local_broadcast(pubsub, topic, message, nil, from) do
    Phoenix.PubSub.local_broadcast_from(pubsub, from, topic, message)
  end

  defp do_local_broadcast(pubsub, topic, message, dispatcher, from) do
    Phoenix.PubSub.local_broadcast_from(pubsub, from, topic, message, dispatcher)
  end

  # ---------------------------------------------------------------------------
  # Batching
  # ---------------------------------------------------------------------------

  defp buffer_message(
         %__MODULE__{buffer: buffer, flush_max_size: flush_max_size, flush_interval_ms: interval} = state,
         topic,
         message,
         dispatcher,
         from
       ) do
    entry = {message, dispatcher, from}
    topic_buffer = [entry | Map.get(buffer, topic, [])]
    new_buffer = Map.put(buffer, topic, topic_buffer)
    state = %{state | buffer: new_buffer}

    flush? = length(topic_buffer) >= flush_max_size or interval == 0
    state = if flush?, do: cancel_timer(state), else: maybe_schedule_flush(state)

    {state, flush?}
  end

  defp maybe_schedule_flush(%__MODULE__{timer: nil, flush_interval_ms: interval} = state) when interval > 0 do
    %{state | timer: Process.send_after(self(), :flush, interval)}
  end

  defp maybe_schedule_flush(state), do: state

  defp cancel_timer(%__MODULE__{timer: nil} = state), do: state

  defp cancel_timer(%__MODULE__{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp flush(%__MODULE__{buffer: buffer, pubsub: pubsub} = state) do
    state = cancel_timer(state)

    Enum.each(buffer, fn {topic, entries} ->
      entries = Enum.reverse(entries)

      case entries do
        [{single_msg, single_dispatcher, single_from}] ->
          do_local_broadcast(pubsub, topic, single_msg, single_dispatcher, single_from)

        _ ->
          entries
          |> Enum.group_by(fn {_msg, dispatcher, _from} -> dispatcher end)
          |> Enum.each(fn {dispatcher, group_entries} ->
            if batch_dispatcher?(dispatcher) do
              batch_payload = Enum.map(group_entries, fn {msg, _dispatcher, from} -> {msg, from} end)

              batch_message = %Phoenix.Socket.Broadcast{
                topic: topic,
                event: @batch_event,
                payload: batch_payload
              }

              do_local_broadcast(pubsub, topic, batch_message, dispatcher, nil)
            else
              Enum.each(group_entries, fn {msg, dispatcher, from} ->
                do_local_broadcast(pubsub, topic, msg, dispatcher, from)
              end)
            end
          end)
      end

      Telemetry.execute([:realtime, :broker, :syn, :flush], %{count: length(entries)}, %{topic: topic})
    end)

    {:noreply, %{state | buffer: %{}}}
  end

  defp batch_dispatcher?(dispatcher) when is_atom(dispatcher) do
    function_exported?(dispatcher, :batch_dispatch?, 0) and dispatcher.batch_dispatch?()
  end

  defp batch_dispatcher?(_dispatcher), do: false
end
