defmodule Realtime.ErlSysMon do
  @moduledoc """
  Logs Erlang System Monitor events.
  """

  use GenServer

  require Logger

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def init(args) do
    config = Keyword.get(args, :config, defaults())
    :erlang.system_monitor(self(), config)

    {:ok, []}
  end

  def handle_info({:monitor, pid, _type, _meta} = msg, state) when is_pid(pid) do
    log_process_info(msg, pid)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__} message: " <> inspect(msg))
    {:noreply, state}
  end

  defp log_process_info(msg, pid) do
    pid_info =
      pid
      |> Process.info(:dictionary)
      |> then(fn
        {:dictionary, dict} when is_list(dict) ->
          {
            List.keyfind(dict, :"$initial_call", 0),
            List.keyfind(dict, :"$ancestors", 0),
            List.keyfind(dict, :tenant_id, 0)
          }

        other ->
          other
      end)

    extra_info = Process.info(pid, [:registered_name, :message_queue_len, :total_heap_size])

    {_, _, tenant_id} = pid_info

    Logger.warning(
      "#{__MODULE__} message: " <>
        inspect(msg) <> "|\n process info: #{inspect(pid_info)} #{inspect(extra_info)}",
      external_id: tenant_id,
      project: tenant_id
    )
  rescue
    _ ->
      Logger.warning("#{__MODULE__} message: " <> inspect(msg))
  end

  defp defaults do
    Process.flag(:max_heap_size, Application.fetch_env!(:realtime, :websocket_max_heap_size))

    [
      :busy_dist_port,
      :busy_port,
      {:long_gc, 500},
      {:long_schedule, 500},
      {:long_message_queue, {0, 1_000}},
      {:large_heap, {0, 1_000}}
    ]
  end
end
