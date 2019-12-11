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

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    adapter_impl(config).init(config)
  end

  @doc """
    0.1.0 Integration test: update public.users
    
    ## Example
      iex> handle_info({:epgsql, 0, {:x_log_data, 0, 0, <<82, 0, 0, 64, 2, 112, 117, 98, 108, 105, 99, 0, 117, 115, 101, 114, 115, 0, 100, 0, 6, 1, 105, 100, 0, 0, 0, 0, 20, 255, 255, 255, 255, 0, 102, 105, 114, 115, 116, 95, 110, 97, 109, 101, 0, 0, 0, 0, 25, 255, 255, 255, 255, 0, 108, 97, 115, 116, 95, 110, 97, 109, 101, 0, 0, 0, 0, 25, 255, 255, 255, 255, 0, 105, 110, 102, 111, 0, 0, 0, 14, 218, 255, 255, 255, 255, 0, 105, 110, 115, 101, 114, 116, 101, 100, 95, 97, 116, 0, 0, 0, 4, 90, 255, 255, 255, 255, 0, 117, 112, 100, 97, 116, 101, 100, 95, 97, 116, 0, 0, 0, 4, 90, 255, 255, 255, 255>>}}, %Realtime.Replication.State{})
      {:noreply, %Realtime.Replication.State{config: [], connection: nil, relations: %{16386 => %PgoutputDecoder.Messages.Relation{columns: [%PgoutputDecoder.Messages.Relation.Column{flags: [:key], name: "id", type: :int8, type_modifier: 4294967295}, %PgoutputDecoder.Messages.Relation.Column{flags: [], name: "first_name", type: :text, type_modifier: 4294967295}, %PgoutputDecoder.Messages.Relation.Column{flags: [], name: "last_name", type: :text, type_modifier: 4294967295}, %PgoutputDecoder.Messages.Relation.Column{flags: [], name: "info", type: :jsonb, type_modifier: 4294967295}, %PgoutputDecoder.Messages.Relation.Column{flags: [], name: "inserted_at", type: :timestamp, type_modifier: 4294967295}, %PgoutputDecoder.Messages.Relation.Column{flags: [], name: "updated_at", type: :timestamp, type_modifier: 4294967295}], id: 16386, name: "users", namespace: "public", replica_identity: :default}}, subscribers: [], transaction: nil, types: %{}}}

  """
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

    # Clearing the state to keep things clean
    %{state | transaction: nil, relations: %{}, types: %{}}
  end

  # Any unknown types will now be populated into state.types
  # This will be utilised later on when updating unidentified data types
  defp process_message(%Type{} = msg, state)do
    
    %{state | types: Map.put(state.types, msg.id, msg.name)}
  end

  defp process_message(%Relation{} = msg, state) do
    updated_columns = Enum.map(msg.columns, fn message ->
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
