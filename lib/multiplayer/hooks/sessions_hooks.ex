defmodule Multiplayer.SessionsHooks do
  require Logger

  @table __MODULE__

  def session_connected(user_id, type, url) do
    insert_event(:session, :connected, user_id, type, url)
  end

  def session_disconnected(user_id, type, url) do
    insert_event(:session, :disconnected, user_id, type, url)
  end

  def session_update(user_id, type, url) do
    insert_event(:session, :update, user_id, type, url)
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

  @spec insert_event(atom, atom, String.t(), String.t(), String.t()) :: true
  def insert_event(event, sub_event, user_id, type, url) do
    :ets.insert(@table, {
      make_ref(),
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
    first_key =
      if !last_key or last_key == :"$end_of_table" do
        :ets.first(@table)
      else
        last_key
      end

    case first_key do
      :"$end_of_table" -> {first_key, []}
      _ ->
        {last_key, keys} = Enum.reduce(1..num, {first_key, [first_key]}, fn
          _, {:"$end_of_table", _} = final -> final
          _, {key, acc} ->
            {:ets.next(@table, key), [key | acc]}
        end)
        records = :ets.select(@table, match_spec(:"$_", keys))
        :ets.select_delete(@table, match_spec(true, keys))
        {last_key, records}
    end
  end

  def match_spec(match, keys) do
    for key <- keys do
      {{key, :_,:_,:_,:_,:_,:_}, [], [match]}
    end
  end

  def insert_dummy_sess_conn(num) do
    Enum.each(1..num, fn n ->
      insert_event(
        :session,
        :connected,
        make_ref(),
        "webhook",
        "http://localhost:4000/" <> Integer.to_string(n)
      )
    end)
  end

end
