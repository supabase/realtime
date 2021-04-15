defmodule Realtime.Interpreter.EventHelper do
  @moduledoc """
  Convert `Workflows.Event` structs to and from values that can be serialized to JSON.
  """

  alias Workflows.Event.{TaskStarted, WaitStarted}

  # TODO: need to encode scope as well

  def wait_started_to_map(event) do
    {seconds, timestamp} =
      case event.wait do
	{:seconds, seconds} -> {seconds, nil}
	{:timestamp, timestamp} -> {nil, timestamp}
      end
    %{
      activity: event.activity,
      scope: event.scope,
      seconds: seconds,
      timestamp: timestamp
    }
  end

  def task_started_to_map(event) do
    Map.from_struct(event)
  end

  def wait_started_from_map(map) do
    wait =
      case {map["seconds"], map["timestamp"]} do
	{seconds, nil} -> {:ok, {:seconds, seconds}}
	{nil, timestamp} -> {:ok, {:timestamp, timestamp}}
	_ -> {:error, :invalid_wait_started_map}
      end

    with {:ok, wait} <- wait do
      event = %WaitStarted{
	activity: map["activity"],
	scope: map["scope"],
	wait: wait
      }
      {:ok, event}
    end
  end

  def task_started_from_map(map) do
    event = %TaskStarted{
      activity: map["activity"],
      scope: map["scope"],
      resource: map["resource"],
      args: map["args"]
    }
    {:ok, event}
  end
end
