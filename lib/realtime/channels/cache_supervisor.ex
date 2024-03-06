defmodule Realtime.Channels.CacheSupervisor do
  @moduledoc """
  Supervisor for Channels Cache and Operational processes
  """
  use Supervisor

  alias Realtime.Channels.Cache

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg), do: Supervisor.init([Cache], strategy: :one_for_one)
end
