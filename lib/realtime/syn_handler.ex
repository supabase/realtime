defmodule Realtime.SynHandler do
  @moduledoc """
  Custom defined Syn's callbacks
  """
  require Logger
  alias Extensions.PostgresCdcRls
  alias RealtimeWeb.Endpoint
  alias Realtime.Tenants.Connect

  @behaviour :syn_event_handler

  @impl true
  def on_registry_process_updated(Connect, tenant_id, _pid, %{conn: conn}, :normal) when is_pid(conn) do
    # Update that a database connection is ready
    Endpoint.local_broadcast(Connect.syn_topic(tenant_id), "ready", %{conn: conn})
  end

  def on_registry_process_updated(PostgresCdcRls, tenant_id, _pid, meta, _reason) do
    # Update that the CdCRls connection is ready
    Endpoint.local_broadcast(PostgresCdcRls.syn_topic(tenant_id), "ready", meta)
  end

  def on_registry_process_updated(_scope, _name, _pid, _meta, _reason), do: :ok

  @doc """
  When processes registered with :syn are unregistered, either manually or by stopping, this
  callback is invoked.

  Other processes can subscribe to these events via PubSub to respond to them.

  We want to log conflict resolutions to know when more than one process on the cluster
  was started, and subsequently stopped because :syn handled the conflict.
  """
  @impl true
  def on_process_unregistered(mod, name, _pid, _meta, reason) do
    case reason do
      :syn_conflict_resolution ->
        Logger.warning("#{mod} terminated: #{inspect(name)} #{node()}")

      _ ->
        topic = topic(mod)
        Endpoint.local_broadcast(topic <> ":" <> name, topic <> "_down", nil)
    end

    :ok
  end

  # resolve_registry_conflict(Scope :: atom(),
  #                           Name :: term(),
  #                           {Pid1 :: pid(), Meta1 :: term(), Time1 :: non_neg_integer()},
  #                           {Pid2 :: pid(), Meta2 :: term(), Time2 :: non_neg_integer()}) ->
  #                              PidToKeep :: pid().
  # %% by default, keep pid registered more recently
  #          %% this is a simple mechanism that can be imprecise, as system clocks are not perfectly aligned in a cluster
  #          %% if something more elaborate is desired (such as vector clocks) use Meta to store data and a custom event handler
  #          PidToKeep = case Time1 > Time2 of
  #              true -> Pid1;
  #              _ -> Pid2
  #          end,
  #          {PidToKeep, true}
  @impl true
  def resolve_registry_conflict(mod, name, {pid1, _meta1, time1}, {pid2, _meta2, time2}) do
    {pid_to_keep, pid_to_stop} = decide(pid1, time2, pid2, time2)

    if node(pid_to_stop) == node() do
      Logger.warning(
        "SynHandler: Resolving conflict on scope #{inspect(mod)} for name #{inspect(name)} {#{inspect(pid1)}, #{time1}} vs {#{inspect(pid2)}, #{time2}}, stop local process: #{inspect(pid_to_stop)}"
      )

      spawn(fn ->
        Process.monitor(pid_to_stop)
        Process.exit(pid_to_stop, {:shutdown, :syn_conflict_resolution})

        receive do
          {:DOWN, _ref, :process, ^pid_to_stop, reason} ->
            Logger.warning("SynHandler: Successfully stopped #{inspect(pid_to_stop)}. Reason: #{inspect(reason)}")
        after
          30_000 ->
            Logger.warning("SynHandler: Timed out while waiting for process #{inspect(pid_to_stop)} to stop")
        end
      end)
    else
      Logger.warning(
        "SynHandler: Resolving conflict on scope #{inspect(mod)} for name #{inspect(name)} {#{inspect(pid1)}, #{time1}} vs {#{inspect(pid2)}, #{time2}}, remote process will be stopped: #{inspect(pid_to_stop)}"
      )
    end

    pid_to_keep
  end

  # If the time on both pids are exactly the same
  # we compare the node names and pick one consistently
  # Node names are necessarily unique
  defp decide(pid1, time1, pid2, time2) when time1 == time2 do
    if node(pid1) < node(pid2) do
      {pid1, pid2}
    else
      {pid2, pid1}
    end
  end

  defp decide(pid1, time1, pid2, time2) do
    # We pick the one that started first.
    if time1 < time2 do
      {pid1, pid2}
    else
      {pid2, pid1}
    end
  end

  defp topic(mod) do
    mod
    |> Macro.underscore()
    |> String.split("/")
    |> Enum.take(-1)
    |> hd()
  end
end
