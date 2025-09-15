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
  def on_registry_process_updated(Connect, tenant_id, pid, %{conn: conn}, :normal) when is_pid(conn) do
    # Update that a database connection is ready
    Endpoint.local_broadcast(Connect.syn_topic(tenant_id), "ready", %{pid: pid, conn: conn})
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
  def on_process_unregistered(mod, name, pid, _meta, reason) do
    if reason == :syn_conflict_resolution do
      log("#{mod} terminated due to syn conflict resolution: #{inspect(name)} #{inspect(pid)}")
    end

    topic = topic(mod)
    Endpoint.local_broadcast(topic <> ":" <> name, topic <> "_down", %{pid: pid, reason: reason})

    :ok
  end

  @doc """
  We try to keep the oldest process. If the time they were registered is exactly the same we use
  their node names to decide.

  The most important part is that both nodes must 100% of the time agree on the decision

  We first send an exit with reason {:shutdown, :syn_conflict_resolution}
  If it times out an exit with reason :kill that can't be trapped
  """
  @impl true
  def resolve_registry_conflict(mod, name, {pid1, _meta1, time1}, {pid2, _meta2, time2}) do
    {pid_to_keep, pid_to_stop} = decide(pid1, time1, pid2, time2)

    # Is this function running on the node that should stop?
    if node(pid_to_stop) == node() do
      log(
        "Resolving conflict on scope #{inspect(mod)} for name #{inspect(name)} {#{inspect(pid1)}, #{time1}} vs {#{inspect(pid2)}, #{time2}}, stop local process: #{inspect(pid_to_stop)}"
      )

      stop(pid_to_stop)
    else
      log(
        "Resolving conflict on scope #{inspect(mod)} for name #{inspect(name)} {#{inspect(pid1)}, #{time1}} vs {#{inspect(pid2)}, #{time2}}, remote process will be stopped: #{inspect(pid_to_stop)}"
      )
    end

    pid_to_keep
  end

  defp stop(pid_to_stop) do
    spawn(fn ->
      Process.monitor(pid_to_stop)
      Process.exit(pid_to_stop, {:shutdown, :syn_conflict_resolution})

      receive do
        {:DOWN, _ref, :process, ^pid_to_stop, reason} ->
          log("Successfully stopped #{inspect(pid_to_stop)}. Reason: #{inspect(reason)}")
      after
        5000 ->
          log("Timed out while waiting for process #{inspect(pid_to_stop)} to stop. Sending kill exit signal")
          Process.exit(pid_to_stop, :kill)
      end
    end)
  end

  defp log(message), do: Logger.warning("SynHandler(#{node()}): #{message}")

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
