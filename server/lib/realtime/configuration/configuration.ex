defmodule Realtime.Configuration do
  defmodule(ConfigurationFileError,
    do: defexception(message: "configuration file is missing required attribute(s)")
  )

  defmodule(WebhookEndpoint, do: defstruct([:endpoint]))
  defmodule(Webhook, do: defstruct([:event, :relation, :config]))
  defmodule(Realtime, do: defstruct([:events, :relation]))

  defmodule(Configuration, do: defstruct(webhooks: [], realtime: []))

  @events ["INSERT", "UPDATE", "DELETE", "TRUNCATE"]

  @doc """

  Load and convert configuration settings from a json file.

  """
  def from_json_file(filename) when is_binary(filename) and filename != "" do
    {:ok,
     filename
     |> File.read!()
     |> Jason.decode!()
     |> convert_raw_config!()}
  end

  def from_json_file(_) do
    {:ok,
     Map.put(
       %Configuration{},
       :realtime,
       [
         %Realtime{
           relation: "*",
           events: @events
         },
         %Realtime{
           relation: "*:*",
           events: @events
         },
         %Realtime{
           relation: "*:*:*",
           events: @events
         }
       ]
     )}
  end

  defp convert_raw_config!(raw_config) do
    default_config = %Configuration{}

    default_config
    |> Map.keys()
    |> Enum.reduce(default_config, fn connector_type, acc_config ->
      convert_connector_config!(acc_config, raw_config, connector_type)
    end)
  end

  defp convert_connector_config!(%Configuration{} = config, %{"webhooks" => webhooks}, :webhooks)
       when is_list(webhooks) do
    webhooks =
      Enum.map(webhooks, fn webhook ->
        case Kernel.get_in(webhook, ["config", "endpoint"]) do
          endpoint when is_binary(endpoint) and endpoint != "" ->
            config_endpoint = %WebhookEndpoint{endpoint: endpoint}
            # default to all events
            event = Map.get(webhook, "event", "*")
            # default to all relations
            relation = Map.get(webhook, "relation", "*")

            %Webhook{event: event, relation: relation, config: config_endpoint}

          _ ->
            raise ConfigurationFileError
        end
      end)

    %Configuration{config | webhooks: webhooks}
  end

  defp convert_connector_config!(%Configuration{}, %{"webhooks" => _}, :webhooks) do
    raise ConfigurationFileError
  end

  defp convert_connector_config!(%Configuration{} = config, _, :webhooks) do
    config
  end

  defp convert_connector_config!(
         %Configuration{} = config,
         %{"realtime" => subscribers},
         :realtime
       )
       when is_list(subscribers) do
    subscribers =
      Enum.map(subscribers, fn subscriber ->
        with {:ok, relation} <- Map.fetch(subscriber, "relation"),
             {:ok, events} <- Map.fetch(subscriber, "events") do
          %Realtime{relation: relation, events: events}
        else
          _ -> raise ConfigurationFileError
        end
      end)

    %Configuration{config | realtime: subscribers}
  end

  defp convert_connector_config!(%Configuration{}, %{"realtime" => _}, :realtime) do
    raise ConfigurationFileError
  end

  defp convert_connector_config!(%Configuration{} = config, _, :realtime) do
    config
  end

  defp convert_connector_config!(%Configuration{} = config, _, :__struct__) do
    config
  end
end
