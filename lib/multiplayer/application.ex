defmodule Multiplayer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    # topologies = Application.get_env(:libcluster, :topologies) || []

    children = [
      # {Cluster.Supervisor, [topologies, [name: MultiplayerWeb.ClusterSupervisor]]},
      # Start the Ecto repository
      Multiplayer.Repo,
      # Start the Telemetry supervisor
      MultiplayerWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: Multiplayer.PubSub},
      # Start the Endpoint (http/https)
      MultiplayerWeb.Endpoint,
      # Start a worker by calling: Multiplayer.Worker.start_link(arg)
      # {Multiplayer.Worker, arg}
      MultiplayerWeb.Presence
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Multiplayer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    MultiplayerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
