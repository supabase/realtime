defmodule Realtime.ConfigurationTest do
  use ExUnit.Case

  alias Realtime.Configuration

  test "parse a configuration from a json file" do
    filename = Path.expand("../support/example_config.json", __DIR__)
    {:ok, config} = Configuration.from_json_file(filename)
    assert Enum.count(config.webhooks) == 3

    webhook = List.first(config.webhooks)
    assert webhook.event == "*"
    assert webhook.relation == "*"
    assert String.starts_with?(webhook.config.endpoint, "https://")
  end
end
