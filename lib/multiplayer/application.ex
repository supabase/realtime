defmodule Multiplayer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger, warn: false

  defmodule JwtSecretError, do: defexception([:message])
  defmodule JwtClaimValidatorsError, do: defexception([:message])

  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies) || []

    if Application.fetch_env!(:multiplayer, :secure_channels) do
      if Application.fetch_env!(:multiplayer, :jwt_secret) == "" do
        raise JwtSecretError, message: "JWT secret is missing"
      end

      case Application.fetch_env!(:multiplayer, :jwt_claim_validators) |> Jason.decode() do
        {:ok, claims} when is_map(claims) ->
          Application.put_env(:multiplayer, :jwt_claim_validators, claims)

        _ ->
          raise JwtClaimValidatorsError,
            message: "JWT claim validators is not a valid JSON object"
      end
    end

    children = [
      {Cluster.Supervisor, [topologies, [name: Multiplayer.ClusterSupervisor]]},
      # Start the Telemetry supervisor
      MultiplayerWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: Multiplayer.PubSub},
      # Start the Endpoint (http/https)
      MultiplayerWeb.Endpoint,
      # Start a worker by calling: Multiplayer.Worker.start_link(arg)
      # {Multiplayer.Worker, arg}
      MultiplayerWeb.Presence,
      Multiplayer.PromEx
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
