defmodule Realtime.Presence do
  @moduledoc """
  The presence API of Realtime. A facade over the Phoenix and Rollcall backends.

  Two feature flags select the mode of a tenant. The facade reads the flags on every call.

    * `presence_rollcall_primary` sets the Rollcall mode. Rollcall serves `list`, `track` and
      `untrack`, and publishes the `presence_diff`. Phoenix tracks nothing.
    * `presence_rollcall_shadow` sets the shadow mode. Phoenix serves the clients. Each `track`
      and `untrack` also goes to Rollcall, which publishes no diff. This mode runs Rollcall on live
      traffic and leaves the clients unaffected.
    * With neither flag, Phoenix serves the clients and Rollcall does nothing.

  The primary flag wins over the shadow flag.
  """
  alias Realtime.Presence.RollcallBackend
  alias Realtime.FeatureFlags
  alias Realtime.Presence.Metrics
  alias Realtime.Presence.PhoenixBackend
  import Realtime.Logs
  require Logger

  @shadow_error_event [:realtime, :presence, :shadow, :error]

  @type tenant :: String.t()
  @type topic :: String.t()
  @type key :: String.t()
  @type action :: :track | :update
  @type state :: %{key() => %{metas: [map()]}}
  @type mode :: :phoenix | :shadow | :rollcall
  @type implementation :: :phoenix | :rollcall

  @doc """
  Returns the implementation that serves the clients of the tenant, as the metrics tag it.

  The shadow mode returns `:phoenix`, because Phoenix serves the clients in that mode.
  """
  @spec implementation_tag(tenant()) :: implementation()
  def implementation_tag(tenant) do
    case mode(tenant) do
      :shadow -> :phoenix
      mode -> mode
    end
  end

  @doc """
  Returns the presence state of the topic, grouped by key.

  Rollcall serves the read in the Rollcall mode. Phoenix serves it in the other modes.
  """
  @spec list(tenant(), topic()) :: state()
  def list(tenant, topic) do
    tenant
    |> mode()
    |> case do
      :rollcall -> RollcallBackend.list(tenant, topic)
      _ -> PhoenixBackend.list(topic)
    end
    |> Metrics.strip_state()
  end

  @doc """
  Tracks the key for the pid. Updates the entry if the pid tracks the key already.

  Returns `{:ok, action, ref}` or `{:error, action, reason}`. `action` is the call that produced
  the result.

  In the shadow mode, Phoenix tracks first. Rollcall tracks only when Phoenix succeeds, and it uses
  the Phoenix ref. A Rollcall error, raise or exit does not change the result. The facade emits
  `[:realtime, :presence, :shadow, :error]` with the `operation` and the `tenant` instead.

  Each backend call emits its own `[:realtime, :presence, :track, :duration]` event, tagged with
  the backend.
  """
  @spec track(pid(), tenant(), topic(), key(), map()) ::
          {:ok, action(), ref :: String.t()} | {:error, action(), reason :: term()}
  def track(pid, tenant, topic, key, meta) do
    case mode(tenant) do
      :phoenix ->
        phoenix_track(pid, tenant, topic, key, meta)

      :rollcall ->
        rollcall_track(pid, tenant, topic, key, meta, [])

      :shadow ->
        with {:ok, _, ref} = result <- phoenix_track(pid, tenant, topic, key, meta) do
          shadow(:track, tenant, fn -> rollcall_track(pid, tenant, topic, key, meta, ref: ref) end)
          result
        end
    end
  end

  defp phoenix_track(pid, tenant, topic, key, meta) do
    Metrics.measure_tracker_call(
      fn -> PhoenixBackend.track(pid, topic, key, Metrics.stamp(meta, tenant, :phoenix)) end,
      :phoenix
    )
  end

  defp rollcall_track(pid, tenant, topic, key, meta, opts) do
    Metrics.measure_tracker_call(
      fn -> RollcallBackend.track(pid, tenant, topic, key, Metrics.stamp(meta, tenant, :rollcall), opts) end,
      :rollcall
    )
  end

  @doc """
  Removes the entry of the key for the pid.

  In the shadow mode, the entry goes from both backends. A Rollcall failure emits the shadow error
  event of `track/5` and does not change the result.
  """
  @spec untrack(pid(), tenant(), topic(), key()) :: :ok
  def untrack(pid, tenant, topic, key) do
    case mode(tenant) do
      :phoenix ->
        PhoenixBackend.untrack(pid, topic, key)

      :rollcall ->
        RollcallBackend.untrack(pid, tenant, topic, key)

      :shadow ->
        PhoenixBackend.untrack(pid, topic, key)
        shadow(:untrack, tenant, fn -> RollcallBackend.untrack(pid, tenant, topic, key) end)
    end
  end

  @doc """
  Makes sure the Rollcall tracker of the tenant runs on this node.

  A node that has listeners and no entry of its own needs the tracker, so that it holds the entries
  of its peers. The channel calls this function when it syncs the presence state.

  In the Phoenix mode, the function starts no tracker and returns `:ok`.

  In the shadow mode, the function returns `:ok`. A Rollcall error, raise or exit does not reach the
  caller. The facade emits `[:realtime, :presence, :shadow, :error]` with the operation `:watch`
  instead, as it does for `track/5`.

  In the Rollcall mode, the function returns `:ok` or `{:error, reason}`. It logs the error, because
  a node with no tracker has no presence state for the tenant.
  """
  @spec watch(tenant()) :: :ok | {:error, term()}
  def watch(tenant) do
    case mode(tenant) do
      :rollcall ->
        case Realtime.Presence.Rollcall.ensure_started(tenant) do
          :ok ->
            :ok

          {:error, error} = result ->
            log_error("RollcallWatchError", error, external_id: tenant)
            result
        end

      :shadow ->
        shadow(:watch, tenant, fn -> Realtime.Presence.Rollcall.ensure_started(tenant) end)

      :phoenix ->
        :ok
    end
  end

  # Runs the Rollcall call of the shadow mode. A failure of that call must not change the result
  # of the Phoenix call, so the facade logs it and emits the shadow error event instead.
  defp shadow(operation, tenant, fun) do
    case fun.() do
      {:error, error} -> log_shadow_error(tenant, operation, error)
      {:error, _action, error} -> log_shadow_error(tenant, operation, error)
      _ -> :ok
    end
  rescue
    error -> log_shadow_error(tenant, operation, error)
  catch
    :exit, reason -> log_shadow_error(tenant, operation, reason)
  end

  @doc """
  Returns the mode of the tenant, from the primary and shadow feature flags.
  """
  @spec mode(tenant()) :: mode()
  def mode(tenant) do
    cond do
      FeatureFlags.enabled?("presence_rollcall_primary", tenant) -> :rollcall
      FeatureFlags.enabled?("presence_rollcall_shadow", tenant) -> :shadow
      true -> :phoenix
    end
  end

  defp log_shadow_error(tenant, operation, error) do
    :telemetry.execute(@shadow_error_event, %{}, %{tenant: tenant, operation: operation})
    log_error(shadow_error_code(operation), error, external_id: tenant)
  end

  defp shadow_error_code(:track), do: "RollcallShadowTrackError"
  defp shadow_error_code(:untrack), do: "RollcallShadowUntrackError"
  defp shadow_error_code(:watch), do: "RollcallShadowWatchError"
end
