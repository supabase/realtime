defmodule RealtimeWeb.TenantBroadcaster do
  @moduledoc """
  gen_rpc broadcaster
  """

  alias Phoenix.PubSub
  alias RealtimeWeb.RealtimeChannel.MessageDispatcher

  @type message_type :: :broadcast | :presence | :postgres_changes

  @type transport :: :ws | :http_single | :http_batch
  @type result :: :ok | :client_error | :tenant_error | :server_error
  @type reason ::
          :none
          | :rate_limited
          | :payload_too_large
          | :invalid_payload
          | :unauthorized
          | :rls_policy_error
          | :query_canceled
          | :tenant_database_unavailable
          | :tenant_db_too_many_connections
          | :missing_partition
          | :increase_connection_pool
          | :connect_rate_limit_reached
          | :tenant_initializing
          | :rpc_error
          | :tenant_suspended
          | :unknown

  @transports [:ws, :http_single, :http_batch]

  @classification %{
    none: :ok,
    rate_limited: :client_error,
    payload_too_large: :client_error,
    invalid_payload: :client_error,
    unauthorized: :client_error,
    tenant_suspended: :client_error,
    rls_policy_error: :tenant_error,
    query_canceled: :tenant_error,
    tenant_database_unavailable: :tenant_error,
    tenant_db_too_many_connections: :tenant_error,
    tenant_initializing: :tenant_error,
    connect_rate_limit_reached: :tenant_error,
    # The tenant's own pool timed out on checkout, or its authorization error rate limit tripped
    increase_connection_pool: :tenant_error,
    missing_partition: :server_error,
    rpc_error: :server_error,
    unknown: :server_error
  }

  @reasons Map.keys(@classification)

  @spec pubsub_direct_broadcast(
          node :: node(),
          tenant_id :: String.t(),
          PubSub.topic(),
          PubSub.message(),
          PubSub.dispatcher(),
          message_type
        ) ::
          :ok
  def pubsub_direct_broadcast(node, tenant_id, topic, message, dispatcher, message_type) do
    collect_payload_size(tenant_id, message, message_type)

    do_direct_broadcast(node, topic, message, dispatcher)

    :ok
  end

  # Remote
  defp do_direct_broadcast(node, topic, message, dispatcher) when node != node() do
    PubSub.direct_broadcast(node, Realtime.PubSub, topic, message, dispatcher)
  end

  # Local
  defp do_direct_broadcast(_node, topic, message, dispatcher) do
    PubSub.local_broadcast(Realtime.PubSub, topic, message, dispatcher)
  end

  @spec pubsub_broadcast(tenant_id :: String.t(), PubSub.topic(), PubSub.message(), PubSub.dispatcher(), message_type) ::
          :ok
  def pubsub_broadcast(tenant_id, topic, message, dispatcher, message_type) do
    collect_payload_size(tenant_id, message, message_type)
    tagged_message = tag_tenant(tenant_id, message, dispatcher, message_type)

    # We measure here for the local dispatch and GenRpcPubSub measures on the remote nodes
    measure_broadcast_fanout(tagged_message)

    PubSub.broadcast(Realtime.PubSub, topic, tagged_message, dispatcher)
    :ok
  end

  @spec pubsub_broadcast_from(
          tenant_id :: String.t(),
          from :: pid,
          PubSub.topic(),
          PubSub.message(),
          PubSub.dispatcher(),
          message_type
        ) ::
          :ok
  def pubsub_broadcast_from(tenant_id, from, topic, message, dispatcher, message_type) do
    collect_payload_size(tenant_id, message, message_type)
    tagged_message = tag_tenant(tenant_id, message, dispatcher, message_type)

    # We measure here for the local dispatch and GenRpcPubSub measures on the remote nodes
    measure_broadcast_fanout(tagged_message)

    PubSub.broadcast_from(
      Realtime.PubSub,
      from,
      topic,
      tagged_message,
      dispatcher
    )

    :ok
  end

  # Tag broadcast messages with their tenant_id so the receiving node can attribute the fan-out
  # (see the telemetry in Realtime.GenRpcPubSub.Worker). Only tag when MessageDispatcher is the
  # dispatcher, since it is the component that unwraps the tag before delivery
  # Presence/postgres_changes stay untagged.
  defp tag_tenant(tenant_id, message, MessageDispatcher, :broadcast), do: {:tb, tenant_id, message}
  defp tag_tenant(_tenant_id, message, _dispatcher, _message_type), do: message

  @fanout_event [:realtime, :broadcast, :fanout, :node_delivery]

  @doc """
  Records whether the current node holds any connection for the broadcast's tenant, so that
  aggregating `hit=false` tells us how many node deliveries could have been avoided.
  """
  @spec measure_broadcast_fanout(message :: term) :: :ok
  def measure_broadcast_fanout({:tb, tenant_id, _message}) do
    count = Forum.Census.local_member_count(:users, tenant_id)

    :telemetry.execute(@fanout_event, %{local_tenant_users: count}, %{tenant: tenant_id, hit: count > 0})
  end

  def measure_broadcast_fanout(_message), do: :ok

  @ingress_event [:realtime, :broadcast, :ingress]

  @doc """
  Counts a broadcast attempt for the Broadcast error-rate SLO.

  Call it once per attempt, at the point where Realtime accepts or rejects the broadcast.
  For several messages with the same outcome, call it once and pass the number of messages as `count`.
  It emits the `[:realtime, :broadcast, :ingress]` telemetry event, which shows up in Prometheus as
  `realtime_broadcast_ingress_total`.

  Callers pass a reason. This function maps the reason to a result:

    * `:ok`: the broadcast went out (reason `:none`)
    * `:client_error`: the caller caused the failure, such as hitting a rate limit
    * `:tenant_error`: the tenant's database caused the failure
    * `:server_error`: Realtime caused the failure

  An unknown transport or reason raises `FunctionClauseError`. That way a typo fails in tests and
  never counts against the error budget.
  """
  @spec record_ingress(transport :: transport, reason :: reason, count :: pos_integer) :: :ok
  def record_ingress(transport, reason, count \\ 1)
      when transport in @transports and reason in @reasons and is_integer(count) and count > 0 do
    result = Map.fetch!(@classification, reason)

    :telemetry.execute(
      @ingress_event,
      %{count: count},
      %{transport: transport, result: result, reason: reason}
    )

    :ok
  end

  @doc """
  Maps an error from `Realtime.Tenants.Connect.lookup_or_start_connection/2` to an ingress reason.

  Use it when a private broadcast fails because Realtime can't get a connection to the tenant's
  database. Pass the result to `record_ingress/3`. Errors this function doesn't know become `:unknown`.
  """
  @spec connect_error_reason({:error, :rpc_error, term()} | {:error, term()}) :: reason
  def connect_error_reason(connect_error) do
    case connect_error do
      {:error, :rpc_error, _} -> :rpc_error
      {:error, :tenant_database_unavailable} -> :tenant_database_unavailable
      {:error, :tenant_db_too_many_connections} -> :tenant_db_too_many_connections
      {:error, :connect_rate_limit_reached} -> :connect_rate_limit_reached
      {:error, :initializing} -> :tenant_initializing
      {:error, :tenant_database_connection_initializing} -> :tenant_initializing
      # Returned when Connect starts the connection on another node and the tenant is suspended
      {:error, :tenant_suspended} -> :tenant_suspended
      _ -> :unknown
    end
  end

  @payload_size_event [:realtime, :tenants, :payload, :size]

  @spec collect_payload_size(tenant_id :: String.t(), payload :: term, message_type :: message_type) :: :ok
  def collect_payload_size(tenant_id, payload, message_type) when is_struct(payload) do
    # Extracting from struct so the __struct__ bit is not calculated as part of the payload
    collect_payload_size(tenant_id, Map.from_struct(payload), message_type)
  end

  def collect_payload_size(tenant_id, payload, message_type) do
    :telemetry.execute(@payload_size_event, %{size: :erlang.external_size(payload)}, %{
      tenant: tenant_id,
      message_type: message_type
    })
  end
end
