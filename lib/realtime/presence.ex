defmodule Realtime.Presence do
  @moduledoc """
  The presence API of Realtime. A facade over the Phoenix and Rollcall backends.

  Note: Currently only has the Phoenix backend, Rollcall will come ina future update,
  along with feature flags to handle different modes.
  """
  alias Realtime.Presence.Metrics
  alias Realtime.Presence.PhoenixBackend

  @type tenant :: String.t()
  @type topic :: String.t()
  @type key :: String.t()
  @type action :: :track | :update
  @type state :: %{key() => %{metas: [map()]}}

  @doc """
  Returns the presence state of the topic, grouped by key.
  """
  @spec list(tenant(), topic()) :: state()
  def list(_tenant, topic) do
    topic
    |> PhoenixBackend.list()
    |> Metrics.strip_state()
  end

  @doc """
  Tracks the key for the pid. Updates the entry if the pid tracks the key already.

  Returns `{:ok, action, ref}` or `{:error, action, reason}`. `action` is the call that produced
  the result. 
  """
  @spec track(pid(), tenant(), topic(), key(), map()) ::
          {:ok, action(), ref :: String.t()} | {:error, action(), reason :: term()}
  def track(pid, tenant, topic, key, meta) do
    Metrics.measure_tracker_call(fn ->
      PhoenixBackend.track(pid, topic, key, Metrics.stamp(meta, tenant))
    end)
  end

  @doc """
  Removes the entry of the key for the pid. 
  """
  @spec untrack(pid(), tenant(), topic(), key()) :: :ok
  def untrack(pid, _tenant, topic, key) do
    PhoenixBackend.untrack(pid, topic, key)
  end
end
