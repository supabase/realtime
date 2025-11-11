defmodule RateCounterHelper do
  alias Realtime.RateCounter

  @spec stop(term()) :: :ok
  def stop(tenant_id) do
    keys =
      Registry.select(Realtime.Registry.Unique, [
        {{{:"$1", :_, {:_, :_, :"$2"}}, :"$3", :_}, [{:==, :"$1", RateCounter}, {:==, :"$2", tenant_id}], [:"$_"]}
      ])

    Enum.each(keys, fn {{_, _, key}, {pid, _}} ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Realtime.GenCounter.delete(key)
      Cachex.del!(RateCounter, key)
    end)

    :ok
  end

  @spec tick!(RateCounter.Args.t()) :: RateCounter.t()
  def tick!(args) do
    [{pid, _}] = Registry.lookup(Realtime.Registry.Unique, {RateCounter, :rate_counter, args.id})
    send(pid, :tick)
    {:ok, :sys.get_state(pid)}
  end

  def tick_tenant_rate_counters!(tenant_id) do
    keys =
      Registry.select(Realtime.Registry.Unique, [
        {{{:"$1", :_, {:_, :_, :"$2"}}, :"$3", :_}, [{:==, :"$1", RateCounter}, {:==, :"$2", tenant_id}], [:"$_"]}
      ])

    Enum.each(keys, fn {{_, _, _key}, {pid, _}} ->
      send(pid, :tick)
      # do a get_state to wait for the tick to be processed
      :sys.get_state(pid)
    end)

    :ok
  end
end
