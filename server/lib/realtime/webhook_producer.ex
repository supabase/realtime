defmodule Realtime.WebhookProducer do
  use GenServer
  require Logger

  alias Realtime.Adapters.Changes.BacklogTransaction
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
  def handle_info({:transaction, %BacklogTransaction{size: size} = txn}, state) do
    if size < 10_000 do
      {:ok, %{webhooks: config}} =
        ConfigurationManager.get_config()
      transaction = RecordLog.backlog_to_simple(:list, txn)
      :ok = WebhookConnector.notify(transaction, config)
    else
      Logger.error("Too big transaction for Webhook, size: #{size}")
    end
    {:noreply, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

end
