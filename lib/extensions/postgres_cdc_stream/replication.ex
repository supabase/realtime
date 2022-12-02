defmodule Extensions.PostgresCdcStream.Replication do
  @moduledoc """
  Subscribes to the Postgres replication slot, decodes write ahead log binary messages
  and broadcasts them to the `MessageDispatcher`.
  """

  use Postgrex.ReplicationConnection
  require Logger

  alias Extensions.PostgresCdcStream, as: Stream
  alias Realtime.Helpers, as: H
  alias Realtime.Adapters.Postgres.Decoder

  alias Decoder.Messages.{
    Begin,
    Relation,
    Insert,
    Update,
    Delete,
    Commit
  }

  alias Realtime.Adapters.Changes.{DeletedRecord, NewRecord, UpdatedRecord}

  def start_link(args) do
    opts = connection_opts(args)

    slot_name =
      if args["dynamic_slot"] do
        args["slot_name"] <> "_" <> (System.system_time(:second) |> Integer.to_string())
      else
        args["slot_name"]
      end

    init = %{
      tenant: args["id"],
      publication: args["publication"],
      slot_name: slot_name
    }

    Postgrex.ReplicationConnection.start_link(__MODULE__, init, opts)
  end

  @spec stop(pid) :: :ok
  def stop(pid) do
    GenServer.stop(pid)
  end

  @impl true
  def init(args) do
    tid = :ets.new(__MODULE__, [:public, :set])
    state = %{tid: tid, step: nil, ts: nil}
    {:ok, Map.merge(args, state)}
  end

  @impl true
  def handle_connect(state) do
    query =
      "CREATE_REPLICATION_SLOT #{state.slot_name} TEMPORARY LOGICAL pgoutput NOEXPORT_SNAPSHOT"

    {:query, query, %{state | step: :create_slot}}
  end

  @impl true
  def handle_result(results, %{step: :create_slot} = state) when is_list(results) do
    query =
      "START_REPLICATION SLOT #{state.slot_name} LOGICAL 0/0 (proto_version '1', publication_names '#{state.publication}')"

    Stream.track_manager(state.tenant, self(), nil)
    {:stream, query, [], %{state | step: :streaming}}
  end

  def handle_result(_results, state) do
    {:noreply, state}
  end

  @impl true
  def handle_data(<<?w, _header::192, msg::binary>>, state) do
    new_state =
      Decoder.decode_message(msg)
      |> process_message(state)

    {:noreply, new_state}
  end

  # keepalive
  def handle_data(<<?k, wal_end::64, _clock::64, reply>>, state) do
    messages =
      case reply do
        1 -> [<<?r, wal_end + 1::64, wal_end + 1::64, wal_end + 1::64, current_time()::64, 0>>]
        0 -> []
      end

    {:noreply, messages, state}
  end

  def handle_data(data, state) do
    Logger.error("Unknown data: #{inspect(data)}")
    {:noreply, state}
  end

  defp process_message(
         %Relation{id: id, columns: columns, namespace: schema, name: table},
         state
       ) do
    columns =
      Enum.map(columns, fn %{name: name, type: type} ->
        %{name: name, type: type}
      end)

    :ets.insert(state.tid, {id, columns, schema, table})
    state
  end

  defp process_message(%Begin{commit_timestamp: ts}, state) do
    %{state | ts: ts}
  end

  defp process_message(%Commit{}, state) do
    %{state | ts: nil}
  end

  defp process_message(%Insert{} = msg, state) do
    Logger.debug("Got message: #{inspect(msg)}")
    [{_, columns, schema, table}] = :ets.lookup(state.tid, msg.relation_id)

    %NewRecord{
      columns: columns,
      commit_timestamp: state.ts,
      errors: nil,
      schema: schema,
      table: table,
      record: data_tuple_to_map(columns, msg.tuple_data),
      type: "UPDATE"
    }
    |> broadcast(state.tenant)

    state
  end

  defp process_message(%Update{} = msg, state) do
    Logger.debug("Got message: #{inspect(msg)}")
    [{_, columns, schema, table}] = :ets.lookup(state.tid, msg.relation_id)

    %UpdatedRecord{
      columns: columns,
      commit_timestamp: state.ts,
      errors: nil,
      schema: schema,
      table: table,
      old_record: data_tuple_to_map(columns, msg.old_tuple_data),
      record: data_tuple_to_map(columns, msg.tuple_data),
      type: "UPDATE"
    }
    |> broadcast(state.tenant)

    state
  end

  defp process_message(%Delete{} = msg, state) do
    Logger.debug("Got message: #{inspect(msg)}")
    [{_, columns, schema, table}] = :ets.lookup(state.tid, msg.relation_id)

    %DeletedRecord{
      columns: columns,
      commit_timestamp: state.ts,
      errors: nil,
      schema: schema,
      table: table,
      old_record: data_tuple_to_map(columns, msg.old_tuple_data),
      type: "UPDATE"
    }
    |> broadcast(state.tenant)

    state
  end

  defp process_message(msg, state) do
    Logger.error("Unknown message: #{inspect(msg)}")
    state
  end

  def broadcast(change, tenant) do
    [
      %{"schema" => "*"},
      %{"schema" => change.schema},
      %{"schema" => change.schema, "table" => "*"},
      %{"schema" => change.schema, "table" => change.table}
    ]
    |> List.foldl([], fn e, acc ->
      [Map.put(e, "event", "*"), Map.put(e, "event", change.type) | acc]
    end)
    |> List.foldl([], fn e, acc ->
      if Map.has_key?(change, :record) do
        Enum.reduce(change.record, [e], fn {k, v}, acc ->
          [Map.put(e, "filter", "#{k}=eq.#{v}") | acc]
        end) ++ acc
      else
        acc
      end
    end)
    |> Enum.each(fn params ->
      Phoenix.PubSub.broadcast_from(
        Realtime.PubSub,
        self(),
        Stream.topic(tenant, params),
        change,
        Stream.MessageDispatcher
      )
    end)
  end

  def data_tuple_to_map(column, tuple_data) do
    column
    |> Enum.with_index()
    |> Enum.reduce_while(%{}, fn {column_map, index}, acc ->
      case column_map do
        %{name: column_name, type: column_type}
        when is_binary(column_name) and is_binary(column_type) ->
          try do
            {:ok, elem(tuple_data, index)}
          rescue
            ArgumentError -> :error
          end
          |> case do
            {:ok, record} ->
              {:cont, Map.put(acc, column_name, convert_column_record(record, column_type))}

            :error ->
              {:halt, acc}
          end

        _ ->
          {:cont, acc}
      end
    end)
  end

  defp convert_column_record(record, "timestamp") when is_binary(record) do
    with {:ok, %NaiveDateTime{} = naive_date_time} <- Timex.parse(record, "{RFC3339}"),
         %DateTime{} = date_time <- Timex.to_datetime(naive_date_time) do
      DateTime.to_iso8601(date_time)
    else
      _ -> record
    end
  end

  defp convert_column_record(record, "timestamptz") when is_binary(record) do
    case Timex.parse(record, "{RFC3339}") do
      {:ok, %DateTime{} = date_time} -> DateTime.to_iso8601(date_time)
      _ -> record
    end
  end

  defp convert_column_record(record, _column_type) do
    record
  end

  @epoch DateTime.to_unix(~U[2000-01-01 00:00:00Z], :microsecond)
  defp current_time(), do: System.os_time(:microsecond) - @epoch

  def connection_opts(args) do
    {host, port, name, user, pass} =
      H.decrypt_creds(
        args["db_host"],
        args["db_port"],
        args["db_name"],
        args["db_user"],
        args["db_password"]
      )

    [
      hostname: host,
      database: name,
      username: user,
      password: pass,
      port: port
    ]
  end
end
