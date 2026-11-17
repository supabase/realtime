defmodule Realtime.Presence.PhoenixBackend do
  @moduledoc """
  Presence backend that calls `RealtimeWeb.Presence`, the Phoenix Presence module.

  `Realtime.Presence` calls this module. It adds the tenant, the metrics and the envelope.
  This module keeps the current Phoenix behavior and does not know the tenant.
  """
  alias Phoenix.Tracker.Shard

  @type topic :: String.t()
  @type key :: String.t()
  @type action :: :track | :update

  @doc """
  Returns the presence state of `topic`, grouped by key, as the `presence_state` event sends it.

  Reads the shard ETS table directly. It does not call the shard process.
  """
  @spec list(topic()) :: %{key() => %{metas: [map()]}}
  def list(topic) do
    [{:pool_size, size}] = :ets.lookup(RealtimeWeb.Presence, :pool_size)

    RealtimeWeb.Presence
    |> Shard.name_for_topic(topic, size)
    |> Shard.dirty_list(topic)
    |> Phoenix.Presence.group()
  end

  @doc """
  Tracks `key` on `topic` for `pid`, or updates the entry when `pid` tracks `key` already.

  Returns `{:ok, :track, ref}` for a new entry and `{:ok, :update, ref}` for an update.
  Returns `{:error, action, reason}` when the call for `action` fails.
  """
  @spec track(pid(), topic(), key(), map()) ::
          {:ok, action(), String.t()} | {:error, action(), term()}
  def track(pid, topic, key, meta) do
    case RealtimeWeb.Presence.track(pid, topic, key, meta) do
      {:error, {:already_tracked, _pid, _, _}} ->
        case RealtimeWeb.Presence.update(pid, topic, key, meta) do
          {:ok, ref} -> {:ok, :update, ref}
          {:error, error} -> {:error, :update, error}
        end

      {:error, error} ->
        {:error, :track, error}

      {:ok, ref} ->
        {:ok, :track, ref}
    end
  end

  @doc """
  Removes the entry of `key` on `topic` for `pid`.
  """
  @spec untrack(pid(), topic(), key()) :: :ok
  def untrack(pid, topic, key) do
    RealtimeWeb.Presence.untrack(pid, topic, key)
  end
end
