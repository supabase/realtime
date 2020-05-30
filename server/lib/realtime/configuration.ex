defmodule Realtime.Configuration do
  defmodule(WebhookEndpoint, do: defstruct([:endpoint]))
  defmodule(Webhook, do: defstruct([:event, :relation, :config]))

  defmodule(Configuration, do: defstruct([:webhooks]))

  @doc """
  Load Configuration from a json file.
  """
  def from_json_file(nil) do
    {:ok, %Configuration{webhooks: []}}
  end
  def from_json_file(filename) do
    with {:ok, body} <- File.read(filename), do: from_json(body)
  end

  @doc """
  Load Configuration from a json string.
  """
  def from_json(body) do
    with {:ok, raw_config} <- Jason.decode(body), do: to_configuration(raw_config)
  end

  defp to_configuration(config) do
    with {:ok, raw_webhooks} <- Map.fetch(config, "webhooks"),
         {:ok, webhooks} <- to_webhooks_configuration(raw_webhooks)
    do
      {:ok, %Configuration{webhooks: webhooks}}
    end
  end

  defp to_webhooks_configuration(config) do
    to_webhooks_configuration(config, [])
  end
  defp to_webhooks_configuration([], acc), do: {:ok, Enum.reverse(acc)}
  defp to_webhooks_configuration([config | rest], acc) do
    case to_webhook_configuration(config) do
      {:ok, config} -> to_webhooks_configuration(rest, [config | acc])
      _ ->  :error
    end
  end


  defp to_webhook_configuration(config) do
    with {:ok, raw_endpoint} <- Map.fetch(config, "config"),
         {:ok, endpoint} <- to_webhook_endpoint_configuration(raw_endpoint)
    do
      event = Map.get(config, "event", "*") # default to all events
      relation = Map.get(config, "relation", "*") # default to all relations
      {:ok, %Webhook{event: event, relation: relation, config: endpoint}}
    end
  end

  defp to_webhook_endpoint_configuration(config) do
    with {:ok,  endpoint} <- Map.fetch(config, "endpoint")
    do
      {:ok, %WebhookEndpoint{endpoint: endpoint}}
    end
  end
end
