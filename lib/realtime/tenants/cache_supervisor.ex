defmodule Realtime.Tenants.CacheSupervisor do
  @moduledoc """
  Supervisor for Tenants Cache and Operational processes
  """
  use Supervisor

  alias Realtime.Tenants.Cache
  alias Realtime.Tenants.CachePubSubHandler

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {CachePubSubHandler, topics: ["realtime:operations:invalidate_cache"]},
      Cache
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
