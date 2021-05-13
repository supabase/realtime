defmodule Realtime.RecordLog do
  alias Realtime.Adapters.Changes.{
    Transaction,
    BacklogTransaction,
    NewRecord,
    UpdatedRecord,
    DeletedRecord,
    TruncatedRelation
  }
  alias Realtime.Adapters.Postgres.Decoder
  alias Decoder.Messages.{
    Relation,
    Insert,
    Update,
    Delete,
    Truncate
  }

  defmodule(Cursor,
    do:
      defstruct(
        io: nil,
        rest: [],
        pos: {0, 0},
        relations: [],
        commit_timestamp: nil
      )
  )

  @type io_device() :: :file.io_device()
  @type posix()     :: :file.posix()
  @type cursor()    :: %Cursor{
                        io: io_device() | nil,
                        rest: list(),
                        pos: {non_neg_integer(), non_neg_integer()},
                        relations: list(),
                        commit_timestamp: nil | %DateTime{}
                       }

  @spec open(String.t()) :: {:ok, io_device()} | {:error, posix()}
  def open(path) when is_binary(path) do
    File.open(path, [:append, :read])
  end

  @spec recreate(String.t()) :: {:ok, io_device()} | {:error, posix()}
  def recreate(path) do
    File.rm(path)
    open(path)
  end

  @spec close(io_device()) :: :ok | {:error, posix() | :badarg | :terminated}
  def close(io) do
    File.close(io)
  end

  @spec remove(String.t()) :: :ok | {:error, posix()}
  def remove(path) when is_binary(path) do
    File.rm(path)
  end

  @spec insert(io_device(), binary()) :: {:ok, pos_integer()} | {:error, any()}
  def insert(io, bin) do
    size = byte_size(bin)
    case :file.write(io, <<size::32, bin::binary>>) do
      :ok -> {:ok, size + 4}
      other -> other
    end
  end

  @spec cursor(map()) :: cursor()
  def cursor(%BacklogTransaction{} = txn) do
    %{
      backlog: {path, start, stop}, 
      init_rels: rels, 
      commit_timestamp: ts
    } = txn    
    chars_path = String.to_charlist(path)
    {:ok, io} = :file.open(chars_path, [:read, :raw, :binary])
    %Cursor{
      io: io, 
      rest: [],
      pos: {start, stop}, 
      relations: rels, 
      commit_timestamp: ts
    }    
  end

  @spec backlog_to_simple(map()) :: map()
  def backlog_to_simple(backlog) do
    %Transaction{
      changes: stream(backlog),
      commit_timestamp: backlog.commit_timestamp
    }
  end

  @spec backlog_to_simple(:list, map()) :: map()
  def backlog_to_simple(:list, backlog) do
    %Transaction{
      changes: stream(backlog) |> Enum.to_list,
      commit_timestamp: backlog.commit_timestamp
    }
  end  

  @spec pop_first(cursor() | :end, pos_integer()) :: {list(), cursor()}
  def pop_first(:end, _), do: nil

  def pop_first(cursor, count) do
    acc_first(cursor, count, [])
  end

  defp acc_first(cursor, 0, acc) do
    {Enum.reverse(acc), cursor}
  end

  defp acc_first(cursor, num, acc) do
    case next(cursor) do
      {record, next_cursor} ->
        acc_first(next_cursor, num - 1, [record | acc])
      :end ->
        {Enum.reverse(acc), :end}
    end  
  end

  def first(%BacklogTransaction{} = transaction) do
    cursor(transaction) |> next()
  end

  def stream(transaction) do
    Stream.resource(
      fn -> cursor(transaction) end,
      fn cursor ->
        case next(%{pos: {next, stop}} = cursor) do
          {record, next_cursor} when next <= stop ->
            {[record], next_cursor}
          _ -> {:halt, cursor}
        end
      end,
      fn %{io: io} -> File.close(io) end
    )    
  end  

  @spec next(cursor()) :: {map(), cursor()} | :end | {:error, any()}
  def next(%Cursor{pos: {start, stop}}) when start >= stop do
    :end
  end

  def next(%Cursor{io: io, pos: {start_pos, stop}} = cursor) do
    case :file.pread(io, start_pos, 4) do
      :eof -> 
        :end
      {:ok, <<len::32>>} ->
        read_record(len, %{cursor | pos: {start_pos + 4, stop}})
      {:error, reason} -> 
        {:error, reason}
    end    
  end

  # truncate
  defp read_record(_, %Cursor{rest: [record | rest]} = cursor) do
    {record, %{cursor | rest: rest}}                
  end

  defp read_record(len, %Cursor{rest: []} = cursor) do
    %{
      io: io, 
      pos: {start, stop}, 
      relations: rels, 
      commit_timestamp: ts
    } = cursor    
    case :file.pread(io, start, len) do
      {:ok, bin} -> 
        decoded = Decoder.decode_message(bin)
        case process_message(decoded, ts, rels) do
          {nil, new_rels} ->
            next(%Cursor{cursor | pos: {start + len, stop}, relations: new_rels})
          # truncate
          {[record | rest], new_rels} ->
            {record, %Cursor{cursor | pos: {start, stop}, relations: new_rels, rest: rest}}            
          {record, new_rels} ->
            {record, %Cursor{cursor | pos: {start + len, stop}, relations: new_rels}}
        end
      _ -> :end
    end    
  end

  defp process_message(%Insert{relation_id: relation_id, tuple_data: tuple_data},
                       commit_timestamp, relations) do
    case relations[relation_id] do
      %{columns: columns, namespace: namespace, name: name} when is_list(columns) ->
        data = data_tuple_to_map(columns, tuple_data)
        {%NewRecord{
          type: "INSERT",
          schema: namespace,
          table: name,
          columns: columns,
          record: data,
          commit_timestamp: commit_timestamp
        }, relations}
      _ ->
        nil
    end
  end

  defp process_message(
         %Truncate{truncated_relations: truncated_relations},
         commit_timestamp, relations)
       when is_list(truncated_relations) and is_map(relations) do
    new_changes =
      Enum.reduce(truncated_relations, [], fn truncated_relation, acc ->
        case relations[truncated_relation] do
          %{namespace: namespace, name: name} ->
            truncate = %TruncatedRelation{
              type: "TRUNCATE",
              schema: namespace,
              table: name,
              commit_timestamp: commit_timestamp
            }
            [truncate | acc]
          _ ->
            acc
        end
      end)
    {new_changes, relations}
  end  

  defp process_message(
         %Update{
           relation_id: relation_id,
           old_tuple_data: old_tuple_data,
           tuple_data: tuple_data
         }, commit_timestamp, relations) when is_map(relations) do
    case relations[relation_id] do
      %{columns: columns, namespace: namespace, name: name} when is_list(columns) ->
        old_data = data_tuple_to_map(columns, old_tuple_data)
        data = data_tuple_to_map(columns, tuple_data)
        {%UpdatedRecord{
          type: "UPDATE",
          schema: namespace,
          table: name,
          columns: columns,
          old_record: old_data,
          record: data,
          commit_timestamp: commit_timestamp
        }, relations}
      _ ->
        nil
    end
  end  

  defp process_message(
         %Delete{
           relation_id: relation_id,
           old_tuple_data: old_tuple_data,
           changed_key_tuple_data: changed_key_tuple_data
         }, commit_timestamp, relations) when is_map(relations) do

    case relations[relation_id] do
      %{columns: columns, namespace: namespace, name: name} ->
        data = data_tuple_to_map(columns, old_tuple_data || changed_key_tuple_data)
        {%DeletedRecord{
          type: "DELETE",
          schema: namespace,
          table: name,
          columns: columns,
          old_record: data,
          commit_timestamp: commit_timestamp
        }, relations}
      _ ->
        nil
    end
  end

  defp process_message(%Relation{} = msg, _, relations) do
    {nil, Map.put(relations, msg.id, msg)}
  end  

  defp process_message(_, _, relations), do: {nil, relations}

  defp data_tuple_to_map(columns, tuple_data) when is_list(columns) and is_tuple(tuple_data) do
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

  defp data_tuple_to_map(_columns, _tuple_data), do: %{} 
  
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

end
