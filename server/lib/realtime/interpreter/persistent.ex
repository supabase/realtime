defmodule Realtime.Interpreter.Persistent do
  @moduledoc """
  """
  use GenServer

  require Logger

  alias EventStore.EventData
  alias Workflows.{Command, Event}
  alias Realtime.EventStore
  alias Realtime.Interpreter.{EventHelper, HandleWaitStartedWorker}

  defmodule State do
    defstruct [:workflow, :execution, :events, :stream_version]
  end

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  ## Callbacks

  @impl true
  def init({workflow, start_type}) do
    state = %State{
      workflow: workflow,
      execution: nil,
      events: [],
      stream_version: 0
    }

    {:ok, state, {:continue, start_type}}
  end

  @impl true
  def handle_continue({:start, ctx, args}, %State{workflow: workflow} = state) do
    Workflows.start(workflow, ctx, args)
    |> continue_with_result(state)
  end

  @impl true
  def handle_continue({:recover, events}, %State{workflow: workflow} = state) do
    events = Enum.map(events, fn stored_event -> stored_event.data end)
    new_state = %State{state | stream_version: length(events)}
    Workflows.recover(workflow, events)
    |> continue_with_result(new_state)
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
        :ok = execute_event_side_effect(event, state)
        {:noreply, %State{state | events: events}, {:continue, :continue_process_events}}
    end
  end

  def handle_cast({:resume_execution, command}, %State{execution: execution} = state) do
    Logger.info("Resume exec #{inspect(command)}")

    Workflows.resume(execution, command)
    |> continue_with_result(state)
  end

  ## Private

  defp process_next_event() do
    GenServer.cast(self(), :process_next_event)
  end

  defp execute_event_side_effect(%Event.WaitStarted{} = event, state) do
    schedule_opts =
      case event.wait do
        {:seconds, seconds} when is_integer(seconds) and seconds > 0 ->
          [schedule_in: seconds]

        {:timestamp, target} ->
          [scheduled_at: target]

        _ ->
          {:error, "Invalid wait duration"}
      end

    execution_id = state.execution.ctx.execution_id
    event_map = EventHelper.wait_started_to_map(event)

    Logger.info("Schedule wait event at #{inspect(schedule_opts)}")

    %{execution_id: execution_id, event: event_map}
    |> HandleWaitStartedWorker.new(schedule_opts)
    |> Oban.insert()

    :ok
  end

  defp execute_event_side_effect(%Event.TaskStarted{} = event, state) do
    # TODO: do it

    :ok
  end

  defp execute_event_side_effect(_event, _state) do
    :ok
  end

  defp continue_with_result({:continue, execution, events}, state) do
    new_state = %State{
      state
      | execution: execution,
        events: state.events ++ events,
        stream_version: state.stream_version + length(events)
    }

    :ok = store_events(events, state.stream_version, execution)

    {:noreply, new_state, {:continue, :continue_process_events}}
  end

  defp continue_with_result({:succeed, result, events}, state) do
    Logger.info("Execution terminated: #{inspect(state.execution)}")
    new_state = %State{
      state
      | events: state.events ++ events,
        stream_version: state.stream_version + length(events)
    }

    :ok = store_events(events, state.stream_version, state.execution)

    {:stop, :normal, state}
  end

  defp store_events([], _stream_version, _execution) do
    Logger.info("Store events: no events to store")
    :ok
  end

  defp store_events(events, stream_version, execution) do
    store_events = Enum.map(events, &create_event_store_event/1)
    execution_id = execution.ctx.execution_id

    Logger.info("Store events: #{inspect execution_id} #{inspect stream_version}")
    EventStore.Store.append_to_stream(execution_id, stream_version, store_events)
  end

  defp create_event_store_event(event) do
    event_type = Atom.to_string(event.__struct__)
    %EventData{
      event_type: event_type,
      data: event,
      metadata: %{}
    }
  end
end
