defmodule Realtime.WebsocketProducer do
  use GenServer
  require Logger

  alias Realtime.Adapters.Changes.BacklogTransaction
  alias Realtime.SubscribersNotification
  alias Realtime.ConfigurationManager
  alias Realtime.RecordLog

  defmodule(State,
    do:
      defstruct(
        mq: [],
        rec_cursor: nil,
        config: nil,
        timer: nil,
        transport_status: {0, nil}
      )
  )

  @mbox_limit Application.get_env(:realtime, :ws_producer_mbox_limit)
  @batch_size Application.get_env(:realtime, :ws_producer_batch_size)
  @wait_time  Application.get_env(:realtime, :ws_producer_wait_time)

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    SubscribersNotification.subscribe(self())
    {:ok, %State{}}
  end

  @impl true
  def handle_info({:transaction, %BacklogTransaction{} = txn}, %{mq: mq} = state) do
    send(self(), :check_mq)
    {:noreply, %{state | mq: mq ++ [txn]}}
  end

  def handle_info(:check_mq, %{mq: []} = state) do
    Logger.debug("MQ is empty")
    {:noreply, state}
  end

  def handle_info(:check_mq, %{mq: [txn | mq], rec_cursor: nil} = state) do
    Logger.debug("Start send transaction to WS #{inspect(txn)}")
    {:ok, %{realtime: config}} = ConfigurationManager.get_config()
    cursor = RecordLog.cursor(txn)
    send(self(), :notification)
    {:noreply, %{state | mq: mq, rec_cursor: cursor, config: config}}
  end

  def handle_info(:notification, %{rec_cursor: :end} = state) do
    Logger.debug("Transaction finished")
    send(self(), :check_mq)
    {:noreply, %{state | rec_cursor: nil}}
  end

  def handle_info(:notification,
                  %{rec_cursor: cursor, config: config, timer: ref,
                    transport_status: {prev_check, prev_status}} = state) do
    clear_timer(ref)
    # check once per sec
    status = if now() != prev_check do
      transport_status()
    else
      {prev_check, prev_status}
    end
    new_state = case status do
      {_, :continue} = stat ->
        {changes, next_cursor} = RecordLog.pop_first(cursor, @batch_size)
        SubscribersNotification.notify_subscribers(changes, config)
        send(self(), :notification)
        %{state | rec_cursor: next_cursor, timer: ref, transport_status: stat}
      {_, :wait} = stat ->
        Logger.debug("Transaction wait")
        ref = Process.send_after(self(), :notification, @wait_time)
        %{state | timer: ref, transport_status: stat}
      _ ->
        send(self(), :check_mq)
        %{state | rec_cursor: nil}
    end
    {:noreply, new_state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  @spec transport_status() :: {pos_integer(), :no_members | :continue | :wait}
  defp transport_status() do
    status = case :pg2.get_members(:realtime_transport_pids) do
      [] -> :no_members
      {:error, _} = err -> err
      pids ->
        if is_transports_busy?(pids, @mbox_limit) do
          :wait
        else 
          :continue
        end
    end
    {now(), status}
  end

  defp is_transports_busy?(pids, mbox_limit) do
    Enum.reduce_while(pids, false, fn pid, _ ->
      case Process.info(pid, :message_queue_len) do
        {_, len} when len < mbox_limit -> {:cont, false}
        _ -> {:halt, true}
      end
    end)
  end

  defp clear_timer(timer) when is_reference(timer) do
    Process.cancel_timer(timer)
  end

  defp clear_timer(_), do: nil

  defp now(), do: System.system_time(:second)

end
