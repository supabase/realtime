defmodule Realtime.RateCounter do
  @moduledoc """
  Start a RateCounter for any Erlang term.

  These rate counters use the GenCounter module which wraps the Erlang :counter module.
  Counts and rates are not ran through the GenServer. `:counters` are addressed
  directly do avoid any serialization bottlenecks.

  Start your RateCounter here and increment it with a `GenCounter.add/1` call, for example.
  """

  use GenServer

  require Logger

  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Telemetry

  @idle_shutdown :timer.seconds(5)
  @tick :timer.seconds(1)
  @max_bucket_len 60
  @cache __MODULE__
  @app_name Mix.Project.config()[:app]

  defstruct id: nil,
            avg: 0.0,
            bucket: [],
            max_bucket_len: @max_bucket_len,
            tick: @tick,
            tick_ref: nil,
            idle_shutdown: @idle_shutdown,
            idle_shutdown_ref: nil,
            telemetry: %{
              event_name: [@app_name] ++ [:rate_counter],
              measurements: %{sum: 0},
              metadata: %{}
            }

  @type t :: %__MODULE__{
          id: term(),
          avg: float(),
          bucket: list(),
          max_bucket_len: integer(),
          tick: integer(),
          tick_ref: reference(),
          idle_shutdown: integer() | :infinity,
          idle_shutdown_ref: reference(),
          telemetry: %{
            emit: false,
            event_name: :telemetry.event_name(),
            measurements: :telemetry.event_measurements(),
            metadata: :telemetry.event_metadata()
          }
        }

  @spec start_link([keyword()]) :: {:ok, pid()} | {:error, {:already_started, pid()}}
  def start_link(args) do
    id = Keyword.get(args, :id)
    unless id, do: raise("Supply an identifier to start a counter!")

    GenServer.start_link(__MODULE__, args,
      name: {:via, Registry, {Realtime.Registry.Unique, {__MODULE__, :rate_counter, id}}}
    )
  end

  @doc """
  Starts a new RateCounter under a DynamicSupervisor
  """

  @spec new(term(), keyword()) :: DynamicSupervisor.on_start_child()
  def new(term, opts \\ []) do
    opts = [id: term] ++ opts

    DynamicSupervisor.start_child(RateCounter.DynamicSupervisor, %{
      id: term,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    })
  end

  @doc """
  Gets the state of the RateCounter.
  """

  @spec get(term()) :: {:ok, term()} | {:error, term()}
  def get(term) do
    case Cachex.get(@cache, term) do
      {:ok, nil} -> {:error, :worker_not_found}
      {:ok, term} -> {:ok, term}
    end
  end

  @impl true
  def init(args) do
    id = Keyword.get(args, :id)
    every = Keyword.get(args, :tick, @tick)
    max_bucket_len = Keyword.get(args, :max_bucket_len, @max_bucket_len)
    idle_shutdown_ms = Keyword.get(args, :idle_shutdown, @idle_shutdown)

    telem_opts = Keyword.get(args, :telemetry)

    telemetry =
      if telem_opts,
        do: %{
          emit: true,
          event_name: [@app_name] ++ [:rate_counter] ++ telem_opts.event_name,
          measurements: Map.merge(%{sum: 0}, telem_opts.measurements),
          metadata: Map.merge(%{id: id}, telem_opts.metadata)
        },
        else: %{emit: false}

    Logger.info("Starting #{__MODULE__} for: #{inspect(id)}")

    ensure_counter_started(id)

    ticker = tick(0)

    idle_shutdown_ref =
      unless idle_shutdown_ms == :infinity, do: shutdown_after(idle_shutdown_ms), else: nil

    state = %__MODULE__{
      id: id,
      tick: every,
      tick_ref: ticker,
      max_bucket_len: max_bucket_len,
      idle_shutdown: idle_shutdown_ms,
      idle_shutdown_ref: idle_shutdown_ref,
      telemetry: telemetry
    }

    Cachex.put!(@cache, id, state)

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.cancel_timer(state.tick_ref)

    {:ok, count} = GenCounter.get(state.id)
    :ok = GenCounter.put(state.id, 0)

    if state.telemetry.emit and count > 0,
      do:
        Telemetry.execute(
          state.telemetry.event_name,
          %{state.telemetry.measurements | sum: count},
          state.telemetry.metadata
        )

    if is_reference(state.idle_shutdown_ref) and count > 0 do
      Process.cancel_timer(state.idle_shutdown_ref)
      shutdown_after(state.idle_shutdown)
    end

    bucket = [count | state.bucket] |> Enum.take(state.max_bucket_len)
    bucket_len = Enum.count(bucket)

    avg =
      bucket
      |> Enum.sum()
      |> Kernel./(bucket_len)

    state = %{state | bucket: bucket, avg: avg}
    tick(state.tick)

    Cachex.put!(@cache, state.id, state)

    {:noreply, state}
  end

  @impl true
  def handle_info(:idle_shutdown, state) do
    Logger.warning("#{__MODULE__} idle_shutdown reached for: #{inspect(state.id)}")
    GenCounter.stop(state.id)
    Cachex.del!(@cache, state.id)
    {:stop, :normal, state}
  end

  defp tick(every) do
    Process.send_after(self(), :tick, every)
  end

  defp shutdown_after(ms) do
    Process.send_after(self(), :idle_shutdown, ms)
  end

  defp ensure_counter_started(id) do
    case GenCounter.get(id) do
      {:ok, _count} -> :ok
      {:error, :counter_not_found} -> GenCounter.new(id)
    end
  end
end
