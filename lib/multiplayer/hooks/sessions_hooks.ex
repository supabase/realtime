defmodule Multiplayer.SessionsHooks do
  require Logger

  @table __MODULE__

  def connected(pid, user_id, type, url) do
    insert_event(:session, :connected, user_id, type, url, pid)
  end

  def disconnected(pid, user_id, type, url) do
    insert_event(:session, :disconnected, user_id, type, url, pid)
  end

  def update(pid, user_id, type, url) do
    insert_event(:session, :update, user_id, type, url, pid)
  end

  def init_table() do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      {:write_concurrency, true}
    ])
  end

  def del_table() do
    :ets.delete(@table)
  end

  def emtpy_table?() do
    :ets.info(@table, :size) == 0
  end

  def flush_data() do
    :ets.delete_all_objects(@table)
  end

  @spec insert_event(pid, atom, atom, String.t(), String.t(), String.t()) :: true
  def insert_event(event, sub_event, user_id, type, url, pid) do
    :ets.insert(@table, {
      make_ref(),
      pid,
      event,
      sub_event,
      user_id,
      type,
      url,
      System.system_time(:second)
    })
  end

  @spec take(pos_integer, any) :: {any, list}
  def take(num, last_key \\ nil) do
    start_key =
      if !last_key or last_key == :"$end_of_table" do
        :ets.first(@table)
      else
        last_key
      end

    case start_key do
      :"$end_of_table" -> {start_key, []}
      _ ->
        {last_key, keys} = Enum.reduce(1..num, {start_key, [start_key]}, fn
          _, {:"$end_of_table", _} = final -> final
          _, {key, acc} ->
            {:ets.next(@table, key), [key | acc]}
        end)
        records = :ets.select(@table, match_spec(:"$_", keys))
        :ets.select_delete(@table, match_spec(true, keys))
        {last_key, Enum.map(records, &msg_transform/1)}
    end
  end

  def msg_transform({_, pid, event, sub_event, user_id, _, url, _}) do
    %{
      pid: pid,
      event: "#{event}.#{sub_event}",
      user_id: user_id,
      url: url
    }
  end

  def match_spec(match, keys) do
    for key <- keys do
      {{key, :_,:_,:_,:_,:_,:_,:_}, [], [match]}
    end
  end

  def insert_dummy_sess_conn(num) do
    Enum.each(1..num, fn n ->
      insert_event(
        self(),
        :session,
        :connected,
        make_ref(),
        "webhook",
        "http://localhost:4000/" <> Integer.to_string(n)
      )
    end)
  end

end
