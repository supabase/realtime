defmodule Realtime.Interpreter.Persistent do
  @moduledoc """
  Persistent workflows interpreter.

  This interpreter uses EventStore to persist state between restarts.
  It also uses EventStore persistent subscriptions to process events
  sequentially with a guaranteed at-least-once delivery.
  """
  use GenServer, restart: :transient

  require Logger

  alias EventStore.EventData
  alias Realtime.EventStore
  alias Workflows.{Command, Event}
  alias Realtime.EventStore
  alias Realtime.Interpreter.{EventHelper, HandleWaitStartedWorker, HandleTaskStartedWorker, ResourceHandler}

  defmodule State do
    defstruct [:workflow, :execution, :execution_id, :stream_version, :subscription]
  end

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  ## Callbacks

  @impl true
  def init({workflow, execution_id, start_type}) do
    {:ok, subscription} = EventStore.Store.subscribe_to_stream(execution_id, execution_id, self())

    state = %State{
      workflow: workflow,
      execution: nil,
      execution_id: execution_id,
      stream_version: 0,
      subscription: subscription
    }

    {:ok, state, {:continue, start_type}}
  end

  @impl true
  def handle_continue({:start, ctx, args}, %State{workflow: workflow} = state) do
    Workflows.start(workflow, ctx, args)
    |> continue_with_result(state)
  end

  def handle_continue(:recover, %State{} = state) do
    {:noreply, state}
  end

  def handle_continue({:process_event, []}, state) do
    {:noreply, state}
  end

  def handle_continue({:process_event, [event | events]}, state) do
    # TODO: what to do in case of error?
    case handle_event(event.data, state.execution_id) do
      :ok ->
        EventStore.Store.ack(state.subscription, event)
    end

    {:noreply, state, {:continue, {:process_event, events}}}
  end

  @impl true
  def handle_cast({:resume_execution, command}, %State{execution: execution} = state) do
    Workflows.resume(execution, command)
    |> continue_with_result(state)
  end

  @impl true
  def handle_info({:subscribed, subscription}, state) do
    Logger.debug("Streaming from subscription #{inspect(subscription)}")
    {:noreply, state}
  end

  def handle_info({:events, events}, state) do
    {:noreply, state, {:continue, {:process_event, events}}}
  end

  ## Private

  defp continue_with_result({:continue, execution, events}, state) do
    new_state = %State{
      state
      | execution: execution,
        stream_version: state.stream_version + length(events)
    }

    :ok = store_events(events, state.stream_version, state.execution_id)

    {:noreply, new_state}
  end

  defp continue_with_result({:succeed, result, events}, state) do
    Logger.debug("Execution terminated with result #{inspect result} #{inspect self()}")

    new_state = %State{
      state
      | stream_version: state.stream_version + length(events)
    }

    :ok = store_events(events, state.stream_version, state.execution_id)
    :ok = EventStore.Store.unsubscribe_from_stream(state.execution_id, state.execution_id)

    {:stop, :normal, new_state}
  end

  defp store_events([], _stream_version, _execution) do
    Logger.info("Store events: no events to store")
    :ok
  end

  defp store_events(events, stream_version, execution_id) do
    store_events = Enum.map(events, &create_event_store_event/1)

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

  defp handle_event(%Event.WaitStarted{} = event, execution_id) do
    schedule_opts =
      case event.wait do
        {:seconds, seconds} when is_integer(seconds) and seconds > 0 ->
          {:ok, [schedule_in: seconds]}

        {:timestamp, target} ->
          {:ok, [scheduled_at: target]}

        _ ->
          {:error, "Invalid wait duration"}
      end

    case schedule_opts do
      {:ok, schedule_opts} ->
        event_map = EventHelper.wait_started_to_map(event)

        Logger.debug("Schedule wait event at #{inspect(schedule_opts)}")

        oban_result =
          %{execution_id: execution_id, event: event_map}
          |> HandleWaitStartedWorker.new(schedule_opts)
          |> Oban.insert()

        case oban_result do
          {:ok, _job} -> :ok
          {:error, error} -> {:error, error}
        end

      {:error, err} ->
        {:error, err}
    end
  end

  defp handle_event(%Event.TaskStarted{} = event, execution_id) do
    event_map = EventHelper.task_started_to_map(event)

    oban_result =
      %{execution_id: execution_id, event: event_map}
      |> HandleTaskStartedWorker.new()
      |> Oban.insert()

    case oban_result do
      {:ok, _job} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp handle_event(_event, _execution_id) do
    :ok
  end
end
