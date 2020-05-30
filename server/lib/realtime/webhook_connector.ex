defmodule Realtime.WebhookConnector do
  # Store the notification function and configuration getter
  # so that we can test the module without mocking.
  defmodule(State, do: defstruct([:notify, :get_config]))

  use GenServer
  require Logger
  alias Realtime.TransactionFilter

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Send notification events to subscribed webhooks
  """
  def notify(txn) do
    GenServer.call(__MODULE__, {:notify, txn})
  end

  @impl true
  def init(nil) do
    state = %State{
      notify: &notify_webhook/2,
      get_config: &Realtime.ConfigurationManager.get_config/1
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:notify, txn}, _from, %State{notify: notify, get_config: get_config} = state) do
    {:ok, config} = get_config.(:webhooks)
    notification_tasks =
      webhooks_for_txn(config, txn)
      |> Enum.map(fn webhook -> notify.(webhook, txn) end)

    notification_results = Task.yield_many(notification_tasks)
    notification_results
    |> Enum.map(fn {_, result} -> handle_notification_result(result) end)

    {:reply, :ok, state}
  end

  defp webhooks_for_txn(config, txn) do
    Enum.filter(config, fn webhook -> TransactionFilter.matches?(webhook, txn) end)
  end

  defp notify_webhook(webhook, txn) do
    Logger.debug("Invoking webhook: #{inspect webhook}")
    serialized = Jason.encode!(txn)
    Task.async(fn ->
      HTTPoison.post(webhook.config.endpoint, serialized, [{"Content-Type", "application/json"}])
    end)
  end

  defp handle_notification_result({:ok, {:ok, %{status_code: status}}})
  when status >= 200 and status < 300, do: []

  defp handle_notification_result({:ok, {:ok, response}}) do
    Logger.warn("Received response with non success status code: #{inspect response}")
  end

  defp handle_notification_result({:ok, {:error, error}}) do
    Logger.warn("Webhook HTTP request failed: #{inspect error} ")
  end

  defp handle_notification_result({:exit, reason}) do
    Logger.warn("Webhook task failed: #{inspect reason} ")
  end
end
