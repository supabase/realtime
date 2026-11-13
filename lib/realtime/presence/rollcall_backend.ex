defmodule Realtime.Presence.RollcallBackend do
  @moduledoc """
  Presence backend that calls Rollcall through `Realtime.Presence.Rollcall`.

  Each call takes the tenant, which is the Rollcall scope. The topic is the partition.
  """
  alias Realtime.Presence.Encoder
  alias Realtime.Presence.Rollcall

  @type tenant :: String.t()
  @type topic :: String.t()
  @type key :: String.t()

  @doc """
  Returns the presence state of `topic`, grouped by key, as the `presence_state` event sends it.
  """
  @spec list(tenant(), topic()) :: Encoder.grouped()
  def list(tenant, topic) do
    tenant
    |> Rollcall.state(topic)
    |> Encoder.state()
  end

  @doc """
  Tracks `key` on `topic` for `pid`, or replaces the entry when `pid` tracks `key` already.

  Returns `{:ok, :track, ref}` for both calls. Rollcall does not tell a track from an update.
  Pass `ref: ref` to use a ref that the caller made, such as a Phoenix ref. Pass `timeout: ms` to
  limit the wait for the tracker. The call exits with `{:timeout, _}` at the limit.
  """
  @spec track(pid(), tenant(), topic(), key(), map(), ref: String.t(), timeout: timeout()) ::
          {:ok, :track, String.t()} | {:error, :track, term()}
  def track(pid, tenant, topic, key, meta, opts \\ []) do
    case Rollcall.track(pid, tenant, topic, key, meta, opts) do
      {:ok, ref} -> {:ok, :track, ref}
      {:error, error} -> {:error, :track, error}
    end
  end

  @doc """
  Removes the entry of `key` on `topic` for `pid`.
  """
  @spec untrack(pid(), tenant(), topic(), key(), timeout: timeout()) :: :ok
  def untrack(pid, tenant, topic, key, opts \\ []) do
    Rollcall.untrack(pid, tenant, topic, key, opts)
  end
end
