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
