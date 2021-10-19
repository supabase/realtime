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

  def take(num) do
    Enum.reduce(1..num, [], fn _, acc ->
      case take_one(@table) do
        [] -> acc
        [record] -> [record | acc]
      end
    end)
  end

  def take_one(@table) do
    case :ets.first(@table) do
      :"$end_of_table" ->
        []
      key ->
        :ets.take(@table, key)
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
