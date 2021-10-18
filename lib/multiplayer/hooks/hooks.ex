defmodule Multiplayer.Hooks do
  require Logger

  @table :multiplayer_hooks

  def session_connected() do
    :session_connected |> insert_event
  end

  def session_disconnected() do
    :session_disconnected |> insert_event
  end

  def session_update() do
    :session_update |> insert_event
  end

  defp insert_event(name) do
    :ets.insert(@table, {
      make_ref(),
      name,
      "user_id",
      "webhook",
      "url",
      System.system_time(:second)
    })
  end
end
