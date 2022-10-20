defmodule Extensions.PostgresCdcStream.WorkerSupervisor do
  @moduledoc false
  use Supervisor
  alias Extensions.PostgresCdcStream, as: Stream

  def start_link(args) do
    name = [name: {:via, :syn, {PostgresCdcStream, args["id"]}}]
    Supervisor.start_link(__MODULE__, args, name)
  end

  @impl true
  def init(args) do
    children = [
      %{
        id: Stream.Replication,
        start: {Stream.Replication, :start_link, [args]},
        restart: :transient
      }
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 10, max_seconds: 60)
  end
end
