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
        config: nil
      )
  )

  @batch_size Application.get_env(:realtime, :ws_producer_batch_size)

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

  def handle_info(:notification, %{rec_cursor: cursor, config: config} = state) do
    {changes, next_cursor} = RecordLog.pop_first(cursor, @batch_size)
    SubscribersNotification.notify_subscribers(changes, config)
    send(self(), :notification)
    {:noreply, %{state | rec_cursor: next_cursor}}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

end
