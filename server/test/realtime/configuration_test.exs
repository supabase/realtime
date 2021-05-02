defmodule Realtime.ConfigurationTest do
  use ExUnit.Case

  alias Realtime.Configuration
  alias Realtime.Configuration.{Realtime, Webhook, WebhookEndpoint}

  test "Realtime.Configuration.from_json_file/1 when filename not given" do
    {:ok, config} = Configuration.from_json_file(nil)

    assert config == %Configuration.Configuration{
             webhooks: [],
             realtime: [
               %Realtime{
                 relation: "*",
                 events: ["INSERT", "UPDATE", "DELETE", "TRUNCATE"]
               },
               %Realtime{
                 relation: "*:*",
                 events: ["INSERT", "UPDATE", "DELETE", "TRUNCATE"]
               },
               %Realtime{
                 relation: "*:*:*",
                 events: ["INSERT", "UPDATE", "DELETE", "TRUNCATE"]
               }
             ]
           }
  end

  test "Realtime.Configuration.from_json_file/1 when file contains an empty JSON object" do
    filename = Path.expand("../support/example_empty_config.json", __DIR__)

    {:ok, config} = Configuration.from_json_file(filename)

    assert config == %Configuration.Configuration{webhooks: [], realtime: []}
  end

  test "Realtime.Configuration.from_json_file/1 when file contains configuration attributes" do
    filename = Path.expand("../support/example_config.json", __DIR__)

    {:ok, config} = Configuration.from_json_file(filename)

    assert config == %Configuration.Configuration{
             realtime: [
               %Realtime{events: ["INSERT", "UPDATE"], relation: "public"},
               %Realtime{events: ["INSERT"], relation: "public:users"},
               %Realtime{events: ["DELETE"], relation: "public:users.id=eq.1"}
             ],
             webhooks: [
               %Webhook{
                 config: %WebhookEndpoint{
                   endpoint: "https://webhook.site/44e4457a-77ae-4758-8d52-17efdf484853"
                 },
                 event: "*",
                 relation: "*"
               },
               %Webhook{
                 config: %WebhookEndpoint{
                   endpoint: "https://webhook.site/44e4457a-77ae-4758-8d52-17efdf484853"
                 },
                 event: "INSERT",
                 relation: "public"
               },
               %Webhook{
                 config: %WebhookEndpoint{
                   endpoint: "https://webhook.site/44e4457a-77ae-4758-8d52-17efdf484853"
                 },
                 event: "UPDATE",
                 relation: "public:users.id=eq.2"
               }
             ]
           }
  end
end
