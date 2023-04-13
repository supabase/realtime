defmodule Realtime.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger, warn: false

  defmodule JwtSecretError, do: defexception([:message])
  defmodule JwtClaimValidatorsError, do: defexception([:message])

  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies) || []

    if Application.fetch_env!(:realtime, :secure_channels) do
      case Application.fetch_env!(:realtime, :jwt_claim_validators) |> Jason.decode() do
        {:ok, claims} when is_map(claims) ->
          Application.put_env(:realtime, :jwt_claim_validators, claims)

        _ ->
          raise JwtClaimValidatorsError,
            message: "JWT claim validators is not a valid JSON object"
      end
    end

    :ok =
      :gen_event.swap_sup_handler(
        :erl_signal_server,
        {:erl_signal_handler, []},
        {Realtime.SignalHandler, []}
      )

    Realtime.PromEx.set_metrics_tags()

    Registry.start_link(
      keys: :duplicate,
      name: Realtime.Registry
    )

    Registry.start_link(
      keys: :unique,
      name: Realtime.Registry.Unique
    )

    :syn.add_node_to_scopes([:users, RegionNodes])
    :syn.join(RegionNodes, System.get_env("FLY_REGION"), self(), node: node())

    extensions_supervisors =
      Enum.reduce(Application.get_env(:realtime, :extensions), [], fn
        {_, %{supervisor: name}}, acc ->
          [
            %{
              id: name,
              start: {name, :start_link, []},
              restart: :transient
            }
            | acc
          ]

        _, acc ->
          acc
      end)

    children =
      [
        Realtime.PromEx,
        {Cluster.Supervisor, [topologies, [name: Realtime.ClusterSupervisor]]},
        Realtime.Repo,
        RealtimeWeb.Telemetry,
        {Phoenix.PubSub, name: Realtime.PubSub, pool_size: 10},
        Realtime.GenCounter.DynamicSupervisor,
        {Cachex, name: Realtime.RateCounter},
        Realtime.Tenants.Cache,
        Realtime.RateCounter.DynamicSupervisor,
        RealtimeWeb.Endpoint,
        RealtimeWeb.Presence,
        {Task.Supervisor, name: Realtime.TaskSupervisor},
        Realtime.Latency,
        Realtime.Telemetry.Logger
      ] ++ extensions_supervisors

    children =
      case Realtime.Repo.replica() do
        Realtime.Repo -> children
        replica_repo -> List.insert_at(children, 2, replica_repo)
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Realtime.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
