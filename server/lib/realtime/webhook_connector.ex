defmodule Realtime.WebhookConnector do
  require Logger

  alias Realtime.Adapters.Changes.Transaction
  alias Realtime.TransactionFilter
  alias Realtime.Configuration.{Webhook, WebhookEndpoint}

  # Task.yield_many/2 timeout default
  @timeout 5_000

  def notify(%Transaction{changes: _} = txn, [_ | _] = config) do
    with [_ | _] = webhooks <- webhooks_for_txn(config, txn),
         {:ok, serialized_txn} <- Jason.encode(txn) do
      Enum.reduce(webhooks, [], fn webhook, acc ->
        case notify_webhook(webhook, serialized_txn) do
          %Task{} = task -> [task | acc]
          :error -> acc
        end
      end)
      |> Task.yield_many(@timeout)
      |> Enum.each(fn {task, result} ->
        handle_notification_result(result)
        # Shut down the tasks that did not reply nor exit
        result || Task.shutdown(task, :brutal_kill)
      end)
    else
      _ -> :ok
    end
  end

  def notify(_txn, _config), do: :ok

  defp webhooks_for_txn(config, txn) do
    Enum.filter(config, fn webhook -> TransactionFilter.matches?(webhook, txn) end)
  end

  defp notify_webhook(
         %Webhook{config: %WebhookEndpoint{endpoint: endpoint}} = webhook,
         serialized_txn
       )
       when is_binary(endpoint) do
    Logger.debug("Invoking webhook: #{inspect(webhook)}")

    headers = Application.fetch_env!(:realtime, :webhook_headers)
    Logger.debug("Webhook headers: #{inspect(headers)}")

    Task.async(fn ->
      HTTPoison.post(endpoint, serialized_txn, headers)
    end)
  end

  defp notify_webhook(_webhook, _serialized_txn), do: :error

  defp handle_notification_result({:ok, {:ok, %{status_code: status}}})
       when status >= 200 and status < 300,
       do: :ok

  defp handle_notification_result({:ok, {:ok, response}}) do
    Logger.warn("Received response with non success status code: #{inspect(response)}")
  end

  defp handle_notification_result({:ok, {:error, error}}) do
    Logger.warn("Webhook HTTP request failed: #{inspect(error)}")
  end

  defp handle_notification_result({:exit, reason}) do
    Logger.warn("Webhook task failed: #{inspect(reason)}")
  end

  defp handle_notification_result(nil) do
    ["Webhook task took longer than ", Integer.to_string(@timeout), " milliseconds to complete"]
    |> IO.iodata_to_binary()
    |> Logger.warn()
  end
end
