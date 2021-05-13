defmodule Realtime.WebsocketProducer do
  use GenServer
  require Logger

  alias Realtime.SubscribersNotification
  alias Realtime.ConfigurationManager
  alias Realtime.RecordLog

  defmodule(State,
    do:
      defstruct(
        mq: [],
        rec_cursor: nil,
        config: nil,
        timer: nil
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
  def handle_info({:transaction, txn}, %{mq: mq} = state) do
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

  def handle_info(:notification, %{rec_cursor: cursor, config: config, timer: ref} = state) do
    clear_timer(ref)
    case transport_status() do
      :continue -> 
        {changes, next_cursor} = RecordLog.pop_first(cursor, @batch_size)
        SubscribersNotification.notify_subscribers(changes, config)
        send(self(), :notification)
        {:noreply, %{state | rec_cursor: next_cursor}}
      :wait -> 
        Logger.debug("Transaction wait")
        ref = Process.send_after(self(), :notification, @wait_time)
        {:noreply, %{state | timer: ref}}
      _ -> 
        send(self(), :check_mq)
        {:noreply, %{state | rec_cursor: nil}}
    end
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  @spec transport_status() :: :no_members | :continue | :wait
  defp transport_status() do
    case :pg2.get_members(:realtime_transport_pids) do
      [] -> :no_members
      {:error, _} = err -> err
      pids -> 
        if max_mbox_len(pids) < @mb_limit do
          :continue
        else 
          :wait
        end
    end
  end

  defp max_mbox_len(pids) do
    Enum.map(pids, fn pid -> 
      {_, len} = Process.info(pid, :message_queue_len); len
    end) |> Enum.max    
  end

  defp clear_timer(timer) when is_reference(timer) do
    Process.cancel_timer(timer)
  end

  defp clear_timer(_), do: nil

end
