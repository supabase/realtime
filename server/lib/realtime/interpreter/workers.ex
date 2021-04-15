defmodule Realtime.Interpreter.HandleWaitStartedWorker do
  use Oban.Worker, queue: :interpreter

  require Logger

  alias Workflows.Command
  alias Realtime.Interpreter
  alias Realtime.Interpreter.EventHelper

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    Logger.warn("HandleWaitStarted fired. #{inspect args}")
    with {:ok, event} <- EventHelper.wait_started_from_map(args["event"]) do
      command = Command.finish_waiting(event)
      :ok = Interpreter.resume_persistent(args["execution_id"], command)
    end
    :ok
  end
end

defmodule Realtime.Interpreter.HandleTaskStartedWorker do
  use Oban.Worker, queue: :interpreter

  require Logger

  alias Workflows.Command
  alias Realtime.Interpreter
  alias Realtime.Interpreter.{EventHelper, ResourceHandler}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    Logger.warn("HandleTaskStarted fired. #{inspect args}")
    with {:ok, event} <- EventHelper.task_started_from_map(args["event"]) do
      # TODO: load context from somewhere
      ctx = %{}
      case ResourceHandler.handle_resource(event.resource, ctx, event.args) do
	{:ok, result} ->
	  command = Command.complete_task(event, result)
	  Interpreter.resume_persistent(args["execution_id"], command)
	{:error, err} ->
	  Logger.error("Error while handling resource: #{inspect event} #{inspect err}")
	  :ok
      end
    end
  end
end
