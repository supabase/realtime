defmodule Multiplayer.HooksProducer do
  use GenStage
  @table :multiplayer_hooks

  def start_link(_opts) do
    GenStage.start_link(__MODULE__, %{})
  end

  def init(_opts) do
    {:producer, %{}}
  end

  def handle_demand(_demand, state) do
    {:noreply, one_hook(), state}
  end

  def one_hook() do
    case :ets.first(@table) do
      :"$end_of_table" ->
        []

      key ->
        :ets.take(@table, key)
    end
  end
end
