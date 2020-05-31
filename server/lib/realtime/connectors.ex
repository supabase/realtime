defmodule Realtime.Connectors do
  use GenServer
  require Logger

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def notify(txn) do
    GenServer.call(__MODULE__, {:notify, txn})
  end

  @impl true
  def init(config) do
    {:ok, nil}
  end

  @impl true
  def handle_call({:notify, txn}, _from, nil) do
    Realtime.WebhookConnector.notify(txn)
    {:reply, :ok, nil}
  end
end
