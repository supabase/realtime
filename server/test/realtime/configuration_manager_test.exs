defmodule Realtime.ConfigurationManagerTest do
  use ExUnit.Case

  alias Realtime.ConfigurationManager

  test "get configuration without a key" do
    state = make_state()
    {:reply, {:ok, %{webhooks: []}}, _} = ConfigurationManager.handle_call({:get_config, nil}, nil, state)
  end

  test "get configuration with a key" do
    state = make_state()
    {:reply, {:ok, []}, _} = ConfigurationManager.handle_call({:get_config, :webhooks}, nil, state)
  end

  defp make_state() do
    %ConfigurationManager.State{
      filename: "path/to/file.json",
      config: %{
	webhooks: []
      }
    }
  end
end
