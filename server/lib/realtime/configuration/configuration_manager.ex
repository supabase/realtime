defmodule Realtime.ConfigurationManager do
  defmodule(State, do: defstruct([:config, :filename]))

  use GenServer
  require Logger

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Get configuration for the given key, or the entire configuration if no key.
  """
  def get_config(key \\ nil) do
    GenServer.call(__MODULE__, {:get_config, key})
  end

  @impl true
  def init(config) do
    filename = Keyword.get(config, :filename)
    {:ok, config} = Realtime.Configuration.from_json_file(filename)
    state = %State{filename: filename, config: config}
    {:ok, state}
  end

  @impl true
  def handle_call({:get_config, key}, _from, %State{config: config} = state) do
    case key do
      nil -> {:reply, {:ok, config}, state}
      _ -> {:reply, Map.fetch(config, key), state}
    end
  end
end
