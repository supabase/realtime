defmodule Realtime.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger
  alias Realtime.Repo.Replica
  defmodule JwtSecretError, do: defexception([:message])
  defmodule JwtClaimValidatorsError, do: defexception([:message])

  def start(_type, _args) do
    primary_config = :logger.get_primary_config()

    # add the region to logs
    :ok =
      :logger.set_primary_config(
        :metadata,
        Enum.into([region: System.get_env("REGION")], primary_config.metadata)
      )

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

    :syn.set_event_handler(Realtime.SynHandler)

    :ok = :syn.add_node_to_scopes([Realtime.Tenants.Connect])
    :ok = :syn.add_node_to_scopes([:users, RegionNodes])

    region = Application.get_env(:realtime, :region)
    :syn.join(RegionNodes, region, self(), node: node())

    children =
      [
        Realtime.ErlSysMon,
        Realtime.PromEx,
        Realtime.Telemetry.Logger,
        Realtime.Repo,
        RealtimeWeb.Telemetry,
        {Cluster.Supervisor, [topologies, [name: Realtime.ClusterSupervisor]]},
        {Phoenix.PubSub, name: Realtime.PubSub, pool_size: 10},
        {Cachex, name: Realtime.RateCounter},
        Realtime.Tenants.CacheSupervisor,
        Realtime.GenCounter.DynamicSupervisor,
        Realtime.RateCounter.DynamicSupervisor,
        Realtime.Latency,
        {Registry, keys: :duplicate, name: Realtime.Registry},
        {Registry, keys: :unique, name: Realtime.Registry.Unique},
        {Task.Supervisor, name: Realtime.TaskSupervisor},
        {PartitionSupervisor,
         child_spec: DynamicSupervisor,
         strategy: :one_for_one,
         name: Realtime.Tenants.Connect.DynamicSupervisor},
        {PartitionSupervisor,
         child_spec: DynamicSupervisor,
         strategy: :one_for_one,
         name: Realtime.Tenants.Listen.DynamicSupervisor,
         max_restarts: 5},
        {DynamicSupervisor,
         name: Realtime.Tenants.Migrations.DynamicSupervisor, strategy: :one_for_one},
        {PartitionSupervisor,
         child_spec: DynamicSupervisor,
         strategy: :one_for_one,
         name: Realtime.BroadcastChanges.Handler.DynamicSupervisor},
        RealtimeWeb.Endpoint,
        RealtimeWeb.Presence
      ] ++ extensions_supervisors() ++ janitor_tasks()

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

  defp janitor_tasks() do
    if Application.fetch_env!(:realtime, :run_janitor) do
      janitor_max_children =
        Application.get_env(:realtime, :janitor_max_children)

      janitor_children_timeout =
        Application.get_env(:realtime, :janitor_children_timeout)

      [
        {Task.Supervisor,
         name: Realtime.Tenants.Janitor.TaskSupervisor,
         max_children: janitor_max_children,
         max_seconds: janitor_children_timeout,
         max_restarts: 1},
        Realtime.Tenants.Janitor
      ]
    else
      []
    end
  end
end
