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
        types: %{},
        should_reset_retry: true
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
  alias Realtime.Adapters.ConnRetry

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    {:ok, %State{config: config}, {:continue, :init_db_conn}}
  end

  @impl true
  def handle_continue(:init_db_conn, %State{config: config} = state) do
    :timer.sleep(Realtime.Adapters.ConnRetry.get_retry_delay())

    case adapter_impl(config).init(config) do
      {:ok, epgsql_pid} ->
        {:noreply, %State{state | connection: epgsql_pid}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(
        {:epgsql, _pid, {:x_log_data, _start_lsn, _end_lsn, binary_msg}},
        %State{should_reset_retry: should_reset_retry} = state
      ) do
    reset_retry_delays(should_reset_retry)
    decoded = Realtime.Decoder.decode_message(binary_msg)
    Logger.debug("Received binary message: #{inspect(binary_msg, limit: :infinity)}")
    Logger.debug("Decoded message: " <> inspect(decoded, limit: :infinity))

    {:noreply, process_message(decoded, Map.put(state, :should_reset_retry, false))}
  end

  @impl true
  def handle_info(msg, state) do
    IO.inspect(msg)
    {:noreply, state}
  end

  defp reset_retry_delays(false) do
    :ok
  end

  defp reset_retry_delays(true) do
    :ok = ConnRetry.reset_retry_delay()
  end

  defp process_message(%Begin{final_lsn: final_lsn, commit_timestamp: commit_timestamp}, state) do
    %State{
      state
      | transaction: {final_lsn, %Transaction{changes: [], commit_timestamp: commit_timestamp}}
    }
  end

  # This will notify subscribers once the transaction has completed
  # FYI: this will be the last function called before returning to the client
  defp process_message(
         %Commit{lsn: commit_lsn, end_lsn: end_lsn},
         %State{transaction: {current_txn_lsn, %Transaction{changes: changes} = txn}} = state
       )
       when commit_lsn == current_txn_lsn do
    # To show how the updated columns look like before being returned
    # Feel free to delete after testing
    Logger.debug("Final Update of Columns " <> inspect(state.relations, limit: :infinity))

    notify_subscribers(%{
      state
      | transaction: {current_txn_lsn, %{txn | changes: Enum.reverse(changes)}}
    })

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

  defp process_message(
         %Insert{relation_id: relation_id, tuple_data: tuple_data},
         %State{
           transaction: {lsn, %{commit_timestamp: commit_timestamp, changes: changes} = txn},
           relations: relations
         } = state
       )
       when is_map(relations) do
    case Map.fetch(relations, relation_id) do
      {:ok, %{columns: columns, namespace: namespace, name: name}} when is_list(columns) ->
        data = data_tuple_to_map(columns, tuple_data)

        new_record = %NewRecord{
          type: "INSERT",
          schema: namespace,
          table: name,
          columns: columns,
          record: data,
          commit_timestamp: commit_timestamp
        }

        %State{state | transaction: {lsn, %{txn | changes: [new_record | changes]}}}

      _ ->
        state
    end
  end

  defp process_message(
         %Update{
           relation_id: relation_id,
           old_tuple_data: old_tuple_data,
           tuple_data: tuple_data
         },
         %State{
           relations: relations,
           transaction: {lsn, %{commit_timestamp: commit_timestamp, changes: changes} = txn}
         } = state
       )
       when is_map(relations) do
    case Map.fetch(relations, relation_id) do
      {:ok, %{columns: columns, namespace: namespace, name: name}} when is_list(columns) ->
        old_data = data_tuple_to_map(columns, old_tuple_data)
        data = data_tuple_to_map(columns, tuple_data)

        updated_record = %UpdatedRecord{
          type: "UPDATE",
          schema: namespace,
          table: name,
          columns: columns,
          old_record: old_data,
          record: data,
          commit_timestamp: commit_timestamp
        }

        %State{
          state
          | transaction: {lsn, %{txn | changes: [updated_record | changes]}}
        }

      _ ->
        state
    end
  end

  defp process_message(
         %Delete{
           relation_id: relation_id,
           old_tuple_data: old_tuple_data,
           changed_key_tuple_data: changed_key_tuple_data
         },
         %State{
           relations: relations,
           transaction: {lsn, %{commit_timestamp: commit_timestamp, changes: changes} = txn}
         } = state
       )
       when is_map(relations) do
    case Map.fetch(relations, relation_id) do
      {:ok, %{columns: columns, namespace: namespace, name: name}} when is_list(columns) ->
        data = data_tuple_to_map(columns, old_tuple_data || changed_key_tuple_data)

        deleted_record = %DeletedRecord{
          type: "DELETE",
          schema: namespace,
          table: name,
          columns: columns,
          old_record: data,
          commit_timestamp: commit_timestamp
        }

        %State{state | transaction: {lsn, %{txn | changes: [deleted_record | changes]}}}

      _ ->
        state
    end
  end

  defp process_message(
         %Truncate{truncated_relations: truncated_relations},
         %State{
           relations: relations,
           transaction: {lsn, %{commit_timestamp: commit_timestamp, changes: changes} = txn}
         } = state
       )
       when is_list(truncated_relations) and is_list(changes) and is_map(relations) do
    new_changes =
      Enum.reduce(truncated_relations, changes, fn truncated_relation, acc ->
        case Map.fetch(relations, truncated_relation) do
          {:ok, %{namespace: namespace, name: name}} ->
            [
              %TruncatedRelation{
                type: "TRUNCATE",
                schema: namespace,
                table: name,
                commit_timestamp: commit_timestamp
              }
              | acc
            ]

          _ ->
            acc
        end
      end)

    %State{
      state
      | transaction: {lsn, %{txn | changes: new_changes}}
    }
  end

  defp process_message(_msg, state) do
    state
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
