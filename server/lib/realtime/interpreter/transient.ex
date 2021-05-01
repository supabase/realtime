defmodule Realtime.Interpreter.Transient do
  @moduledoc """
  The transient interpreter executes a workflow without storing state. Execution is not guaranteed to terminate.

  The interpreter is implemented using a GenServer since it needs to handle multiple children processes (for parallel
  and map activities), and keep state around.

  Side effects are handled as follows:

   * Wait - Send a delayed message to the gen server to continue.
   * Task - Start a Task that handles the task, then sends a message to the supervisor with the task result.
  """
  use GenServer, restart: :transient

  require Logger

  alias Workflows.{Command, Event}

  defmodule State do
    defstruct [:workflow, :execution, :events, :reply_to]
  end

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  ## Callbacks

  @impl true
  def init({workflow, ctx, args, opts}) do
    reply_to = Keyword.get(opts, :reply_to, nil)

    state = %State{
      workflow: workflow,
      execution: nil,
      events: [],
      reply_to: reply_to
    }

    {:ok, state, {:continue, {:start, ctx, args}}}
  end

  @impl true
  def handle_continue({:start, ctx, args}, %State{workflow: workflow} = state) do
    Workflows.start(workflow, ctx, args)
    |> continue_with_result(state)
  end

  def handle_continue(:continue_process_events, state) do
    process_next_event()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:process_next_event, %State{execution: execution, events: events} = state) do
    case events do
      [] ->
        # Finished processing all events, wait for side effects to complete
        {:noreply, state}

      [event | events] ->
        :ok = execute_event_side_effect(event)
        {:noreply, %State{state | events: events}, {:continue, :continue_process_events}}
    end
  end

  @impl true
  def handle_info({:finish_waiting, event}, %State{execution: execution} = state) do
    command = Command.finish_waiting(event)

    Workflows.resume(execution, command)
    |> continue_with_result(state)
  end

  def handle_info({:complete_task, event, result}, %State{execution: execution} = state) do
    command = Command.complete_task(event, result)

    Workflows.resume(execution, command)
    |> continue_with_result(state)
  end

  ## Private

  defp process_next_event() do
    GenServer.cast(self(), :process_next_event)
  end

  defp execute_event_side_effect(%Event.WaitStarted{} = event) do
    duration =
      case event.wait do
        {:seconds, seconds} when is_integer(seconds) and seconds > 0 ->
          trunc(seconds * 1000)

        {:timestamp, target} ->
          DateTime.diff(target, DateTime.utc_now(), :millisecond)

        _ ->
          {:error, "Invalid wait duration"}
      end

    Process.send_after(self(), {:finish_waiting, event}, duration)
    :ok
  end

  defp execute_event_side_effect(%Event.TaskStarted{} = event) do
    server_pid = self()

    Task.start(fn ->
      # TODO: execute task
      send(server_pid, {:complete_task, event, %{}})
    end)

    :ok
  end

  defp execute_event_side_effect(_event) do
    :ok
  end

  defp continue_with_result({:continue, execution, events}, state) do
    new_state = %State{
      state
      | execution: execution,
        events: state.events ++ events
    }

    {:noreply, new_state, {:continue, :continue_process_events}}
  end

  defp continue_with_result({:succeed, result, events}, state) do
    if is_pid(state.reply_to) do
      send(state.reply_to, {:succeed, result})
    end

    {:stop, :normal, state}
  end
end
