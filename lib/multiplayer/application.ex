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
      case Application.fetch_env!(:multiplayer, :jwt_claim_validators) |> Jason.decode() do
        {:ok, claims} when is_map(claims) ->
          Application.put_env(:multiplayer, :jwt_claim_validators, claims)

        _ ->
          raise JwtClaimValidatorsError,
            message: "JWT claim validators is not a valid JSON object"
      end
    end

    Registry.start_link(keys: :duplicate, name: Multiplayer.Registry)
    Registry.start_link(keys: :unique, name: Multiplayer.Registry.Unique)

    Multiplayer.SessionsHooks.init_table()

    children = [
      {Cluster.Supervisor, [topologies, [name: Multiplayer.ClusterSupervisor]]},
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
      MultiplayerWeb.Presence,
      Multiplayer.PromEx,
      Multiplayer.PresenceNotify,
      Multiplayer.SessionsHooksBroadway
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
