# This file draws heavily from https://github.com/cainophile/cainophile
# License: https://github.com/cainophile/cainophile/blob/master/LICENSE

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

  alias Realtime.Decoder.Messages.{
    Begin,
    Commit,
    Relation,
    Insert,
    Update,
    Delete,
    Truncate,
    Type
  }

  alias Realtime.SubscribersNotification

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    adapter_impl(config).init(config)
  end

  @impl true
  def handle_info({:epgsql, _pid, {:x_log_data, _start_lsn, _end_lsn, binary_msg}}, state) do
    decoded = Realtime.Decoder.decode_message(binary_msg)
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
  # FYI: this will be the last function called before returning to the client
  defp process_message(
         %Commit{lsn: commit_lsn, end_lsn: end_lsn},
         %State{transaction: {current_txn_lsn, _txn}} = state
       )
       when commit_lsn == current_txn_lsn do
    # To show how the updated columns look like before being returned
    # Feel free to delete after testing
    Logger.debug("Final Update of Columns " <> inspect(state.relations, limit: :infinity))

    notify_subscribers(state)
    :ok = adapter_impl(state.config).acknowledge_lsn(state.connection, end_lsn)

    %{state | transaction: nil}
  end

  # Any unknown types will now be populated into state.types
  # This will be utilised later on when updating unidentified data types
  defp process_message(%Type{} = msg, state) do
    %{state | types: Map.put(state.types, msg.id, msg.name)}
  end

  defp process_message(%Relation{} = msg, state) do
    updated_columns =
      Enum.map(msg.columns, fn message ->
        if Map.has_key?(state.types, message.type) do
          %{message | type: state.types[message.type]}
        else
          message
        end
      end)

    updated_relations = %{msg | columns: updated_columns}

    %{state | relations: Map.put(state.relations, msg.id, updated_relations)}
  end

  defp process_message(%Insert{} = msg, state) do
    relation = Map.get(state.relations, msg.relation_id)

    data = data_tuple_to_map(relation.columns, msg.tuple_data)

    new_record = %NewRecord{
      type: "INSERT",
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

  defp notify_subscribers(%State{transaction: {_current_txn_lsn, txn}}) do
    SubscribersNotification.notify(txn)
  end
end
