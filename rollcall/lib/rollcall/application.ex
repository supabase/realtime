defmodule Rollcall.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Rollcall.Registry},
      {DynamicSupervisor, name: Rollcall.TrackerSupervisor}
    ]

    opts = [strategy: :rest_for_one, name: Rollcall.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
