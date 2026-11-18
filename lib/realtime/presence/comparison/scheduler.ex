defmodule Realtime.Presence.Comparison.Scheduler do
  @moduledoc """
  Starts a sweep of the comparison at a fixed period.

  The first sweep starts after one period. Each sweep runs in its own task under
  `Realtime.TaskSupervisor`, so a crash of a sweep does not stop the scheduler. A tick that finds
  the previous sweep still running starts no sweep. The sweep number counts the sweeps that
  started, beginning at 0.
  """
  use GenServer
  use Realtime.Logs

  alias Realtime.Presence.Comparison.Sweep

  @default_period 300_000

  @doc """
  Starts the scheduler.

  Options:

    * `:name` - the name of the process. The default is the name of this module.
    * `:period` - the time in milliseconds between the ticks. The default is 5 minutes.
    * `:sweep` - a function that takes the sweep number and runs the sweep. The default is
      `Realtime.Presence.Comparison.Sweep.run/1`. That function checks the feature flag.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      period: Keyword.get(opts, :period, @default_period),
      sweep: Keyword.get(opts, :sweep, &Sweep.run/1),
      number: 0,
      task: nil
    }

    schedule(state)

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule(state)

    {:noreply, start_sweep(state)}
  end

  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    log_error("PresenceComparisonSweepCrashed", reason)

    {:noreply, %{state | task: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A tick starts no sweep while the previous sweep runs.
  defp start_sweep(%{task: %Task{}} = state), do: state

  defp start_sweep(%{sweep: sweep, number: number} = state) do
    task = Task.Supervisor.async_nolink(Realtime.TaskSupervisor, fn -> sweep.(number) end)

    %{state | task: task, number: number + 1}
  end

  defp schedule(%{period: period}) do
    Process.send_after(self(), :tick, period)
  end
end
