defmodule Extensions.PostgresCdcStream.WorkerSupervisor do
  @moduledoc false
  use Supervisor
  alias Extensions.PostgresCdcStream, as: Stream

  alias Realtime.Api
  alias Realtime.PostgresCdc.Exception

  def start_link(args) do
    name = [name: {:via, :syn, {PostgresCdcStream, args["id"]}}]
    Supervisor.start_link(__MODULE__, args, name)
  end

  @impl true
  def init(%{"id" => tenant} = args) when is_binary(tenant) do
    if !Api.get_tenant_by_external_id(tenant, :primary), do: raise(Exception)
    Logger.metadata(external_id: tenant, project: tenant)

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
