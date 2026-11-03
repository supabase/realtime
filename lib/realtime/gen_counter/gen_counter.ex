defmodule Realtime.GenCounter do
  @moduledoc """
  Process holds an ETS table where each row is a key and a counter
  """

  use GenServer

  @name __MODULE__
  @table :gen_counter

  @spec start_link(any) :: GenServer.on_start()
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: @name)

  @spec add(term, integer) :: integer
  def add(term), do: add(term, 1)

  def add(term, count), do: :ets.update_counter(@table, term, count, {term, 0})

  @spec get(term) :: integer
  def get(term) do
    case :ets.lookup(@table, term) do
      [{^term, value}] -> value
      [] -> 0
    end
  end

  @doc "Reset counter to 0 and return previous value"
  @spec reset(term) :: integer
  def reset(term) do
    case :ets.lookup(@table, term) do
      [{^term, 0}] ->
        0

      [{^term, previous}] ->
        # Subtract the value read instead of overwriting with 0. An add between the lookup and
        # the update stays in the counter.
        # The threshold clamps at 0 when a concurrent reset has already subtracted the same value.
        # The default row recreates a counter deleted between the lookup and the update, at 0.
        :ets.update_counter(@table, term, {2, -previous, 0, 0}, {term, previous})
        previous

      [] ->
        0
    end
  end

  @spec delete(term) :: :ok
  def delete(term) do
    :ets.delete(@table, term)
    :ok
  end

  @impl true
  def init(_) do
    table =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        {:decentralized_counters, true},
        {:write_concurrency, :auto}
      ])

    {:ok, table}
  end
end
