# This file draws heavily from https://github.com/cainophile/cainophile
# License: https://github.com/cainophile/cainophile/blob/master/LICENSE

defmodule Realtime.Replication do
  defmodule(State,
    do:
      defstruct(
        relations: %{},
        reverse_changes: [],
        transaction: nil,
        types: %{}
      )
  )

  use GenServer

  require Logger

  alias Realtime.Adapters.Changes.Transaction

  alias Realtime.Adapters.Postgres.Decoder.Messages.{
    Begin,
    Commit,
    Relation,
    Insert,
    Update,
    Delete,
    Truncate,
    Type
  }

  alias Realtime.Adapters.Postgres.EpgsqlServer
  alias Realtime.SubscribersNotification

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %State{}}
  end

  @impl true
  def handle_info({:epgsql, _pid, {:x_log_data, _start_lsn, _end_lsn, binary_msg}}, state) do
    decoded = Realtime.Adapters.Postgres.Decoder.decode_message(binary_msg)
    Logger.debug("Received binary message: #{inspect(binary_msg, limit: :infinity)}")
    Logger.debug("Decoded message: " <> inspect(decoded, limit: :infinity))

    case process_message(decoded, state) do
      {new_state, :hibernate} -> {:noreply, new_state, :hibernate}
      new_state -> {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    IO.inspect(msg)
    {:noreply, state}
  end

  def data_tuple_to_map(columns, tuple_data) when is_list(columns) and is_tuple(tuple_data) do
    columns
    |> Enum.with_index()
    |> Enum.reduce_while(%{}, fn {column_map, index}, acc ->
      case column_map do
        %Relation.Column{name: column_name, type: column_type}
        when is_binary(column_name) and is_binary(column_type) ->
          try do
            {:ok, Kernel.elem(tuple_data, index)}
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

  def data_tuple_to_map(_columns, _tuple_data), do: %{}

  defp process_message(%Begin{final_lsn: final_lsn, commit_timestamp: commit_timestamp}, state) do
    %{
      state
      | reverse_changes: [],
        transaction: {final_lsn, %Transaction{commit_timestamp: commit_timestamp}}
    }
  end

  # This will notify subscribers once the transaction has completed
  # FYI: this will be the last function called before returning to the client
  defp process_message(
         %Commit{lsn: commit_lsn, end_lsn: end_lsn},
         %State{
           reverse_changes: reverse_changes,
           relations: relations,
           transaction: {current_txn_lsn, %Transaction{} = txn_struct} = transaction
         } = state
       )
       when commit_lsn == current_txn_lsn do
    # To show how the updated columns look like before being returned
    # Feel free to delete after testing
    Logger.debug("Final Update of Columns " <> inspect(relations, limit: :infinity))

    :ok =
      %{
        state
        | reverse_changes: [],
          transaction:
            put_elem(transaction, 1, %{txn_struct | changes: Enum.reverse(reverse_changes)})
      }
      |> SubscribersNotification.notify()

    :ok = EpgsqlServer.acknowledge_lsn(end_lsn)

    {%{state | reverse_changes: [], transaction: nil}, :hibernate}
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
           reverse_changes: reverse_changes,
           relations: relations
         } = state
       )
       when is_map(relations) do
    case Map.fetch(relations, relation_id) do
      {:ok, _} ->
        new_record = change_record(relation_id, "INSERT", tuple_data)

        %{state | reverse_changes: [new_record | reverse_changes]}

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
           reverse_changes: reverse_changes,
           relations: relations
         } = state
       )
       when is_map(relations) do
    case Map.fetch(relations, relation_id) do
      {:ok, _} ->
        update_record = change_record(relation_id, "UPDATE", tuple_data, old_tuple_data)

        %{state | reverse_changes: [update_record | reverse_changes]}

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
           reverse_changes: reverse_changes,
           relations: relations
         } = state
       )
       when is_map(relations) do
    case Map.fetch(relations, relation_id) do
      {:ok, _} ->
        delete_record =
          change_record(relation_id, "DELETE", nil, old_tuple_data || changed_key_tuple_data)

        %{state | reverse_changes: [delete_record | reverse_changes]}

      _ ->
        state
    end
  end

  defp process_message(
         %Truncate{truncated_relations: truncated_relations},
         %State{
           reverse_changes: reverse_changes,
           relations: relations
         } = state
       )
       when is_list(truncated_relations) and is_map(relations) do
    new_reverse_changes =
      Enum.reduce(truncated_relations, reverse_changes, fn relation_id, acc ->
        case Map.fetch(relations, relation_id) do
          {:ok, _} ->
            [
              change_record(relation_id, "TRUNCATE")
              | acc
            ]

          _ ->
            acc
        end
      end)

    %{state | reverse_changes: new_reverse_changes}
  end

  defp process_message(_msg, state) do
    state
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

  defp change_record(relation_id, record_type, tuple_data \\ nil, old_tuple_data \\ nil) do
    {relation_id, record_type, tuple_data, old_tuple_data}
  end
end
