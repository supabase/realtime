defmodule Realtime.BroadcastChanges.Handler do
  @moduledoc """
  This module is responsible for handling the replication messages sent from Realtime.BroadcastChanges.PostgresReplication.

  It will specifically setup the PostgresReplication configuration and handle the messages received from the replication stream on the table "realtime.messages".

  ## Options
  * `:tenant_id` - The tenant's external_id to connect to.

  """
  use GenServer
  require Logger

  import Realtime.Adapters.Postgres.Protocol
  import Realtime.Adapters.Postgres.Decoder
  import Realtime.Helpers, only: [log_error: 2]

  alias Realtime.Adapters.Postgres.Decoder
  alias Realtime.Adapters.Postgres.Protocol.KeepAlive
  alias Realtime.Adapters.Postgres.Protocol.Write
  alias Realtime.Api.Tenant
  alias Realtime.BroadcastChanges.PostgresReplication
  alias Realtime.Database
  alias Realtime.Tenants.BatchBroadcast
  alias Realtime.Tenants.Cache

  defstruct [:tenant_id, relations: %{}, buffer: [], postgres_replication_pid: nil]

  @behaviour PostgresReplication.Handler
  @registry Realtime.BroadcastChanges.Handler.Registry
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, opts)

  @impl true
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    tenant = Cache.get_tenant_by_external_id(tenant_id)
    connection_opts = Database.from_tenant(tenant, "realtime_broadcast_changes", :stop, true)

    supervisor =
      {:via, PartitionSupervisor,
       {Realtime.BroadcastChanges.Listener.DynamicSupervisor, tenant_id}}

    name = {:via, Registry, {Realtime.BroadcastChanges.Listener.Registry, tenant_id}}

    configuration = %PostgresReplication{
      connection_opts: [
        hostname: connection_opts.host,
        username: connection_opts.user,
        password: connection_opts.pass,
        database: connection_opts.name,
        port: connection_opts.port,
        parameters: [
          application_name: connection_opts.application_name
        ]
      ],
      table: "messages",
      schema: "realtime",
      handler_module: __MODULE__,
      opts: [name: name],
      metadata: %{tenant_id: tenant_id}
    }

    children_spec = %{
      id: Handler,
      start: {PostgresReplication, :start_link, [configuration]},
      type: :worker
    }

    state = %__MODULE__{tenant_id: tenant_id, buffer: [], relations: %{}}

    case DynamicSupervisor.start_child(supervisor, children_spec) do
      {:ok, pid} ->
        {:ok, %{state | postgres_replication_pid: pid}}

      {:error, {:already_started, pid}} ->
        {:ok, %{state | postgres_replication_pid: pid}}

      error ->
        log_error("UnableToStartPostgresReplication", error)
        {:stop, error}
    end
  end

  @spec name(Tenant.t()) :: term()
  def name(%Tenant{external_id: tenant_id}) do
    {:via, Registry, {@registry, tenant_id}}
  end

  @spec supervisor_spec(Tenant.t()) :: term()
  def supervisor_spec(%Tenant{external_id: tenant_id}) do
    {:via, PartitionSupervisor, {Realtime.BroadcastChanges.Handler.DynamicSupervisor, tenant_id}}
  end

  @impl true
  def call(message, metadata) when is_write(message) do
    %{tenant_id: tenant_id} = metadata
    %Write{message: message} = parse(message)

    case Registry.lookup(@registry, tenant_id) do
      [{pid, _}] ->
        message |> decode_message() |> then(&send(pid, &1))
        :noreply

      _ ->
        Logger.error("Unable to find BroadcastChanges for tenant: #{tenant_id}")
        :shutdown
    end
  end

  def call(message, _metadata) when is_keep_alive(message) do
    %KeepAlive{reply: reply, wal_end: wal_end} = parse(message)
    wal_end = wal_end + 1

    message =
      case reply do
        :now -> standby_status(wal_end, wal_end, wal_end, reply)
        :later -> hold()
      end

    {:reply, message}
  end

  def call(msg, state) do
    Logger.warning("Unknown message received: #{inspect(%{msg: parse(msg), state: state})}")
    :noreply
  end

  @impl true
  def handle_info(%Decoder.Messages.Relation{} = msg, state) do
    %Decoder.Messages.Relation{id: id, namespace: namespace, name: name, columns: columns} = msg
    %{relations: relations} = state
    relation = %{name: name, columns: columns, namespace: namespace}
    relations = Map.put(relations, id, relation)
    {:noreply, %{state | relations: relations}}
  end

  def handle_info(%Decoder.Messages.Insert{} = msg, state) do
    %Decoder.Messages.Insert{relation_id: relation_id, tuple_data: tuple_data} = msg
    %{buffer: buffer, relations: relations} = state

    case Map.get(relations, relation_id) do
      %{columns: columns} ->
        to_broadcast =
          tuple_data
          |> Tuple.to_list()
          |> Enum.zip(columns)
          |> Map.new(fn
            {nil, %{name: name}} -> {name, nil}
            {value, %{name: name, type: "jsonb"}} -> {name, Jason.decode!(value)}
            {value, %{name: name, type: "bool"}} -> {name, value == "t"}
            {value, %{name: name}} -> {name, value}
          end)

        payload = Map.get(to_broadcast, "payload")

        case payload do
          nil ->
            {:noreply, state}

          payload ->
            id = Map.fetch!(to_broadcast, "id")

            to_broadcast =
              %{
                topic: Map.fetch!(to_broadcast, "topic"),
                event: Map.fetch!(to_broadcast, "event"),
                private: Map.fetch!(to_broadcast, "private"),
                payload: Map.put(payload, "id", id)
              }

            buffer = Enum.reverse([to_broadcast | buffer])
            {:noreply, %{state | buffer: buffer}}
        end

      _ ->
        log_error("UnknownBroadcastChangesRelation", "Relation ID not found: #{relation_id}")
        {:noreply, state}
    end
  end

  def handle_info(%Decoder.Messages.Commit{}, %{buffer: []} = state) do
    {:noreply, state}
  end

  def handle_info(%Decoder.Messages.Commit{}, state) do
    %{buffer: buffer, tenant_id: tenant_id} = state
    tenant = Realtime.Tenants.Cache.get_tenant_by_external_id(tenant_id)

    case BatchBroadcast.broadcast(nil, tenant, %{messages: buffer}, true) do
      :ok -> :ok
      error -> log_error("UnableToBatchBroadcastChanges", error)
    end

    {:noreply, %{state | buffer: []}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(reason, _state) do
    log_error("BroadcastChangesHandlerTerminated", reason)
    :ok
  end
end
