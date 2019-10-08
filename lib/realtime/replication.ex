defmodule Realtime.Replication do
  defmodule(State,
    do:
      defstruct(
        config: [],
        connection: nil,
        subscribers: [],
        transaction: nil,
        relations: %{},
        types: %{}
      )
  )

  use GenServer
  require Logger

  alias Realtime.Adapters.Changes.{
    Transaction,
    NewRecord,
    UpdatedRecord,
    DeletedRecord,
    TruncatedRelation
  }

  alias PgoutputDecoder.Messages.{
    Begin,
    Commit,
    Relation,
    Insert,
    Update,
    Delete,
    Truncate,
    Type
  }

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    adapter_impl(config).init(config)
  end

  @impl true
  def handle_info({:epgsql, _pid, {:x_log_data, _start_lsn, _end_lsn, binary_msg}}, state) do
    decoded = PgoutputDecoder.decode_message(binary_msg)
    Logger.debug("Received binary message: #{inspect(binary_msg, limit: :infinity)}")
    Logger.debug("Decoded message: " <> inspect(decoded, limit: :infinity))

    {:noreply, process_message(decoded, state)}
  end

  @impl true
  def handle_info(msg, state) do
    IO.inspect(msg)
    {:noreply, state}
  end

  defp process_message(%Begin{} = msg, state) do
    %{
      state
      | transaction:
          {msg.final_lsn, %Transaction{changes: [], commit_timestamp: msg.commit_timestamp}}
    }
  end

  # This will notify subscribers once the transaction has completed
  defp process_message(
        %Commit{lsn: commit_lsn, end_lsn: end_lsn},
        %State{transaction: {current_txn_lsn, _txn}} = state
      )
      when commit_lsn == current_txn_lsn do

    notify_subscribers(state)
    :ok = adapter_impl(state.config).acknowledge_lsn(state.connection, end_lsn)

    %{state | transaction: nil}
  end

  # TODO: do something more intelligent here
  defp process_message(%Type{}, state), do: state

  defp process_message(%Relation{} = msg, state) do
    %{state | relations: Map.put(state.relations, msg.id, msg)}
  end

  defp process_message(%Insert{} = msg, state) do
    relation = Map.get(state.relations, msg.relation_id)

    data = data_tuple_to_map(relation.columns, msg.tuple_data)

    new_record = %NewRecord{
      type: "INSERT",
      relation: [relation.namespace, relation.name],
      schema: relation.namespace,
      table: relation.name, 
      columns: relation.columns,
      record: data
    }

    {lsn, txn} = state.transaction
    %{state | transaction: {lsn, %{txn | changes: Enum.reverse([new_record | txn.changes])}}}
  end

  defp process_message(%Update{} = msg, state) do
    relation = Map.get(state.relations, msg.relation_id)

    old_data = data_tuple_to_map(relation.columns, msg.old_tuple_data)
    data = data_tuple_to_map(relation.columns, msg.tuple_data)

    updated_record = %UpdatedRecord{
      type: "UPDATE",
      relation: [relation.namespace, relation.name],
      schema: relation.namespace,
      table: relation.name,
      columns: relation.columns,
      old_record: old_data,
      record: data
    }

    {lsn, txn} = state.transaction
    %{state | transaction: {lsn, %{txn | changes: Enum.reverse([updated_record | txn.changes])}}}
  end

  defp process_message(%Delete{} = msg, state) do
    relation = Map.get(state.relations, msg.relation_id)

    data =
      data_tuple_to_map(
        relation.columns,
        msg.old_tuple_data || msg.changed_key_tuple_data
      )

    deleted_record = %DeletedRecord{
      type: "DELETE",
      relation: [relation.namespace, relation.name],
      schema: relation.namespace,
      table: relation.name,
      columns: relation.columns,
      old_record: data
    }

    {lsn, txn} = state.transaction
    %{state | transaction: {lsn, %{txn | changes: Enum.reverse([deleted_record | txn.changes])}}}
  end

  defp process_message(%Truncate{} = msg, state) do
    truncated_relations =
      for truncated_relation <- msg.truncated_relations do
        relation = Map.get(state.relations, truncated_relation)

        %TruncatedRelation{
          type: "TRUNCATE",
          relation: [relation.namespace, relation.name],
          schema: relation.namespace,
          table: relation.name
        }
      end

    {lsn, txn} = state.transaction

    %{
      state
      | transaction: {lsn, %{txn | changes: Enum.reverse(truncated_relations ++ txn.changes)}}
    }
  end

  # TODO: Typecast to meaningful Elixir types here later
  defp data_tuple_to_map(_columns, nil), do: %{}

  defp data_tuple_to_map(columns, tuple_data) do
    for {column, index} <- Enum.with_index(columns, 1),
        do: {column.name, :erlang.element(index, tuple_data)},
        into: %{}
  end

  defp adapter_impl(config) do
    Keyword.get(config, :postgres_adapter, Realtime.Adapters.Postgres.EpgsqlImplementation)
  end

  # Send an event via the Phoenix Channel
  defp notify_subscribers(%State{transaction: {_current_txn_lsn, txn}}) do
    # Logger.info("FULL STATE txn" <> inspect(txn))
    RealtimeWeb.RealtimeChannel.handle_info(txn)

    # Event handled
    {:noreply, :event_received}
  end

end
