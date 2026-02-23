defmodule Realtime.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  alias Realtime.Repo.Replica
  alias Realtime.Tenants.ReplicationConnection
  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Migrations

  defmodule JwtSecretError, do: defexception([:message])
  defmodule JwtClaimValidatorsError, do: defexception([:message])
  defmodule RegionMappingError, do: defexception([:message])

  def start(_type, _args) do
    opentelemetry_setup()
    primary_config = :logger.get_primary_config()

    # add the region to logs
    :ok =
      :logger.set_primary_config(
        :metadata,
        Enum.into([region: System.get_env("REGION"), cluster: System.get_env("CLUSTER")], primary_config.metadata)
      )

    topologies = Application.get_env(:libcluster, :topologies) || []

    case Application.fetch_env!(:realtime, :jwt_claim_validators) |> Jason.decode() do
      {:ok, claims} when is_map(claims) ->
        Application.put_env(:realtime, :jwt_claim_validators, claims)

      _ ->
        raise JwtClaimValidatorsError,
          message: "JWT claim validators is not a valid JSON object"
    end

    setup_region_mapping()

    :ok =
      :gen_event.swap_sup_handler(
        :erl_signal_server,
        {:erl_signal_handler, []},
        {Realtime.SignalHandler, %{handler_mod: :erl_signal_handler}}
      )

    :ets.new(Realtime.Tenants.Connect, [:named_table, :set, :public])
    :syn.set_event_handler(Realtime.SynHandler)
    :ok = :syn.add_node_to_scopes([RegionNodes, Realtime.Tenants.Connect])

    region = Application.get_env(:realtime, :region)
    broadcast_pool_size = Application.get_env(:realtime, :broadcast_pool_size, 10)
    presence_pool_size = Application.get_env(:realtime, :presence_pool_size, 10)
    presence_broadcast_period = Application.get_env(:realtime, :presence_broadcast_period, 1_500)
    presence_permdown_period = Application.get_env(:realtime, :presence_permdown_period, 1_200_000)
    migration_partition_slots = Application.get_env(:realtime, :migration_partition_slots)
    connect_partition_slots = Application.get_env(:realtime, :connect_partition_slots)
    no_channel_timeout_in_ms = Application.get_env(:realtime, :no_channel_timeout_in_ms)
    master_region = Application.get_env(:realtime, :master_region) || region
    user_scope_shards = Application.fetch_env!(:realtime, :users_scope_shards)
    user_scope_broadast_interval_in_ms = Application.get_env(:realtime, :users_scope_broadcast_interval_in_ms, 10_000)

    :syn.join(RegionNodes, region, self(), node: node())

    children =
      [
        Realtime.ErlSysMon,
        Realtime.GenCounter,
        Realtime.PromEx,
        Realtime.TenantPromEx,
        {Realtime.Telemetry.Logger, handler_id: "telemetry-logger"},
        RealtimeWeb.Telemetry,
        {Cluster.Supervisor, [topologies, [name: Realtime.ClusterSupervisor]]},
        {Phoenix.PubSub,
         name: Realtime.PubSub, pool_size: 10, adapter: pubsub_adapter(), broadcast_pool_size: broadcast_pool_size},
        {Beacon,
         [
           :users,
           [
             partitions: user_scope_shards,
             broadcast_interval_in_ms: user_scope_broadast_interval_in_ms,
             message_module: Realtime.BeaconPubSubAdapter
           ]
         ]},
        {Cachex, name: Realtime.RateCounter},
        Realtime.Tenants.Cache,
        Realtime.RateCounter.DynamicSupervisor,
        Realtime.Latency,
        {Registry, keys: :duplicate, name: Realtime.Registry},
        {Registry, keys: :unique, name: Realtime.Registry.Unique},
        {Registry, keys: :unique, name: Realtime.Tenants.Connect.Registry},
        {Registry, keys: :unique, name: Extensions.PostgresCdcRls.ReplicationPoller.Registry},
        {Registry,
         keys: :duplicate, partitions: System.schedulers_online() * 2, name: RealtimeWeb.SocketDisconnect.Registry},
        {Task.Supervisor, name: Realtime.TaskSupervisor},
        {Task.Supervisor, name: Realtime.Tenants.Migrations.TaskSupervisor},
        {PartitionSupervisor,
         child_spec: {DynamicSupervisor, max_restarts: 0},
         strategy: :one_for_one,
         name: Migrations.DynamicSupervisor,
         partitions: migration_partition_slots},
        {PartitionSupervisor,
         child_spec: DynamicSupervisor,
         strategy: :one_for_one,
         name: ReplicationConnection.DynamicSupervisor,
         partitions: connect_partition_slots},
        {PartitionSupervisor,
         child_spec: DynamicSupervisor,
         strategy: :one_for_one,
         name: Connect.DynamicSupervisor,
         partitions: connect_partition_slots},
        {RealtimeWeb.RealtimeChannel.Tracker, check_interval_in_ms: no_channel_timeout_in_ms},
        RealtimeWeb.Endpoint,
        {RealtimeWeb.Presence,
         pool_size: presence_pool_size,
         broadcast_period: presence_broadcast_period,
         permdown_period: presence_permdown_period}
      ] ++ extensions_supervisors() ++ janitor_tasks() ++ metrics_pusher_children()

    database_connections = if master_region == region, do: [Realtime.Repo], else: [Replica.replica()]

    children = database_connections ++ children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Realtime.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp extensions_supervisors do
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

  defp janitor_tasks do
    if Application.get_env(:realtime, :run_janitor) do
      janitor_max_children = Application.get_env(:realtime, :janitor_max_children)
      janitor_children_timeout = Application.get_env(:realtime, :janitor_children_timeout)

      [
        {
          Task.Supervisor,
          name: Realtime.Tenants.Janitor.TaskSupervisor,
          max_children: janitor_max_children,
          max_seconds: janitor_children_timeout,
          max_restarts: 1
        },
        Realtime.Tenants.Janitor,
        Realtime.MetricsCleaner
      ]
    else
      []
    end
  end

  defp metrics_pusher_children do
    if Application.get_env(:realtime, :metrics_pusher_enabled) do
      [Realtime.MetricsPusher]
    else
      []
    end
  end

  defp opentelemetry_setup do
    :opentelemetry_cowboy.setup()
    OpentelemetryPhoenix.setup(adapter: :cowboy2)
    OpentelemetryEcto.setup([:realtime, :repo], db_statement: :enabled)
  end

  defp pubsub_adapter do
    if Application.fetch_env!(:realtime, :pubsub_adapter) == :gen_rpc do
      Realtime.GenRpcPubSub
    else
      Phoenix.PubSub.PG2
    end
  end

  defp setup_region_mapping do
    case Application.get_env(:realtime, :region_mapping) do
      nil ->
        :ok

      mapping_json when is_binary(mapping_json) ->
        case Jason.decode(mapping_json) do
          {:ok, mapping} when is_map(mapping) ->
            if Enum.all?(mapping, fn {k, v} -> is_binary(k) and is_binary(v) end) do
              Application.put_env(:realtime, :region_mapping, mapping)
            else
              raise RegionMappingError,
                message: "REGION_MAPPING must contain only string keys and values"
            end

          {:ok, _} ->
            raise RegionMappingError,
              message: "REGION_MAPPING must be a JSON object"

          {:error, %Jason.DecodeError{} = error} ->
            raise RegionMappingError,
              message: "Failed to parse REGION_MAPPING: #{Exception.message(error)}"
        end
    end
  end
end
