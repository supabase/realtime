defmodule Realtime.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger, warn: false
  alias Realtime.Repo.Replica
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

    :syn.set_event_handler(Realtime.SynHandler)

    :ok = :syn.add_node_to_scopes([Realtime.Tenants.Connect])
    :ok = :syn.add_node_to_scopes([:users, RegionNodes])

    region = Application.get_env(:realtime, :region)
    :syn.join(RegionNodes, region, self(), node: node())

    children =
      [
        Realtime.ErlSysMon,
        Realtime.PromEx,
        {Cluster.Supervisor, [topologies, [name: Realtime.ClusterSupervisor]]},
        Realtime.Repo,
        RealtimeWeb.Telemetry,
        {Phoenix.PubSub, name: Realtime.PubSub, pool_size: 10},
        Realtime.GenCounter.DynamicSupervisor,
        {Cachex, name: Realtime.RateCounter},
        Realtime.Tenants.CacheSupervisor,
        Realtime.RateCounter.DynamicSupervisor,
        RealtimeWeb.Endpoint,
        RealtimeWeb.Presence,
        {Task.Supervisor, name: Realtime.TaskSupervisor},
        Realtime.Latency,
        Realtime.Telemetry.Logger,
        {PartitionSupervisor,
         child_spec: DynamicSupervisor,
         strategy: :one_for_one,
         name: Realtime.Tenants.Connect.DynamicSupervisor}
      ] ++ extensions_supervisors()

    children =
      case Replica.replica() do
        Realtime.Repo -> children
        replica -> List.insert_at(children, 2, replica)
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Realtime.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp extensions_supervisors() do
    Enum.reduce(Application.get_env(:realtime, :extensions), [], fn
      {_, %{supervisor: name}}, acc ->
        opts = %{
          id: name,
          start: {name, :start_link, []},
          restart: :transient
        }

        [opts | acc]

      _, acc ->
        acc
    end)
  end
end
