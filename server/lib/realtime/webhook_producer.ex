defmodule Realtime.WebhookProducer do
  use GenServer
  require Logger

  alias Realtime.SubscribersNotification
  alias Realtime.ConfigurationManager
  alias Realtime.WebhookConnector
  alias Realtime.RecordLog

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    SubscribersNotification.subscribe(self())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:transaction, txn}, state) do
    {:ok, %{webhooks: config}} =
      ConfigurationManager.get_config()
    transaction = RecordLog.backlog_to_simple(:list, txn)
    :ok = WebhookConnector.notify(transaction, config)
    {:noreply, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

end
