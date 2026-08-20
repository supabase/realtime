defmodule Realtime.MusterDrainer do
  @moduledoc """
  Owns the graceful handoff of this node's Muster **router role** at shutdown.

  It does nothing while alive; the whole job is `terminate/2` calling
  `Forum.Muster.drain/2`. Its child spec sets a `shutdown:` timeout large enough
  to cover drain's `timeout_ms + settle_ms` plus slack -- the surrounding SIGTERM
  grace period must exceed that or the BEAM is SIGKILLed mid-drain.
  """
  use GenServer
  require Logger

  # Must exceed Forum.Muster.drain/2's timeout_ms + settle_ms (defaults 5s + 5s)
  # so terminate/2 can finish the handoff before the supervisor brutal-kills us.
  @default_shutdown_ms 20_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Keyword.get(opts, :shutdown, @default_shutdown_ms)
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    scope = Keyword.get(opts, :scope) || Application.fetch_env!(:realtime, :muster_scope)
    drain_opts = Keyword.get(opts, :drain_opts, [])
    {:ok, %{scope: scope, drain_opts: drain_opts}}
  end

  @impl true
  def terminate(_reason, %{scope: scope, drain_opts: drain_opts}) do
    Logger.info("#{__MODULE__}: draining Muster router role for scope #{inspect(scope)}")

    case Forum.Muster.drain(scope, drain_opts) do
      :ok ->
        Logger.info("#{__MODULE__}: Muster drain complete for scope #{inspect(scope)}")

      {:timeout, unacked} ->
        Logger.warning(
          "#{__MODULE__}: Muster drain timed out for scope #{inspect(scope)}; unacked peers: #{inspect(unacked)}"
        )
    end

    :ok
  catch
    kind, reason ->
      # Never let a drain failure stall shutdown: the coordinator may already be
      # gone, or drain may raise. Log and let termination proceed.
      Logger.error(
        "#{__MODULE__}: Muster drain crashed for scope #{inspect(scope)}: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      :ok
  end
end
