defmodule Realtime.SynHandler do
  @moduledoc """
  Custom defined Syn's callbacks
  """
  require Logger
  alias RealtimeWeb.Endpoint

  @doc """
  When processes registered with :syn are unregistered, either manually or by stopping, this
  callback is invoked.

  Other processes can subscribe to these events via PubSub to respond to them.

  We want to log conflict resolutions to know when more than one process on the cluster
  was started, and subsequently stopped because :syn handled the conflict.
  """
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

  def resolve_registry_conflict(mod, name, process1, process2) do
    [{keep, _, _}, {stop, _, _}] = Enum.sort_by([process1, process2], &elem(&1, 2))

    if node() == node(stop),
      do: spawn(fn -> resolve_conflict(mod, stop, name) end),
      else: Logger.warning("Resolving #{name} conflict, remote pid: #{inspect(stop)}")

    keep
  end

  defp resolve_conflict(mod, stop, name) do
    resp =
      if Process.alive?(stop) do
        try do
          Process.exit(stop, :shutdown)
        catch
          error, reason -> {:error, {error, reason}}
        end
      else
        :not_alive
      end

    topic = topic(mod)
    Endpoint.broadcast(topic <> ":" <> name, topic <> "_down", nil)

    Logger.warning("Resolving #{name} conflict, stop local pid: #{inspect(stop)}, response: #{inspect(resp)}")
  end

  defp topic(mod) do
    mod
    |> Macro.underscore()
    |> String.split("/")
    |> Enum.take(-1)
    |> hd()
  end
end
