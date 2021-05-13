defmodule Realtime.BacklogReplication do
  use GenServer
  require Logger

  alias Realtime.Adapters.Changes.BacklogTransaction
  alias Realtime.Adapters.Postgres.Decoder.Messages.Begin
  alias Realtime.Adapters.Postgres.Decoder
  alias Realtime.SubscribersNotification
  alias Realtime.RecordLog

  @type io_device() :: :file.io_device()

  defmodule(State,
    do:
      defstruct(
        relations: %{},
        transaction: nil,
        types: %{},
        io_ref: nil,
        log_path: nil,
        size: 0,
        bin_position: {0, 0},
        prev_rels: %{},
        curr_rels: %{},
        rotated_num: nil
      )
  )

  @file_size Application.get_env(:realtime, :backlog_file_size)
  @max_files Application.get_env(:realtime, :backlog_max_files)

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    num = 1
    {io, path} = rotated_log_file(num)
    {:ok, %State{io_ref: io, log_path: path, rotated_num: num}}    
  end

  @impl true
  def handle_info({:epgsql, _, {:x_log_data, _, _, msg}}, state) do
    new_state = handle_message(msg, state)
    {:noreply, new_state}
  end

  # Begin message
  defp handle_message(<<"B", _::binary-8, _::integer-64, _::integer-32>> = msg, %{transaction: nil} = state) do
    %Begin{
      final_lsn: lsn,
      commit_timestamp: ts
    } = Decoder.decode_message(msg)
    txn = %BacklogTransaction{
      final_lsn: lsn,
      commit_timestamp: ts
    }
    %State{state | transaction: txn}
  end

  # Relation message
  defp handle_message(<<"R", _::integer-32, _::binary>> = msg, state) do
    %{
      io_ref: io,
      size: size,
      curr_rels: rels,
      bin_position: pos
    } = state
    {:ok, size} = RecordLog.insert(io, msg)
    new_rels = update_rels(msg, rels)
    new_pos = calc_position(pos, size)
    %State{state | curr_rels: new_rels, bin_position: new_pos, size: size + 1}
  end

  # Commit message
  defp handle_message(<<"C", _::binary-1, _::binary-8, _::binary-8, _::integer-64>> = msg, state) do
    %{
      io_ref: io,
      size: size,
      curr_rels: rels,
      bin_position: {start, stop},
      rotated_num: num,
      log_path: path
    } = state
    decoded = Decoder.decode_message(msg)
    if decoded.lsn != state.transaction.final_lsn do
      Logger.error("Foreign Commit message #{inspect(decoded)}")
      state
    else
      txn = %BacklogTransaction{
        state.transaction |
        size: size,
        backlog: {path, start, stop},
        init_rels: rels
      }
      SubscribersNotification.async_notify(txn)
      {{new_io, new_path}, new_num} = update_rotated_file(io, path, num)
      %State{
        state |
        bin_position: {stop, stop},
        size: 0,
        transaction: nil,
        prev_rels: rels,
        io_ref: new_io,
        log_path: new_path,
        rotated_num: new_num
      }
    end
  end

  # Other message
  defp handle_message(msg, state) do
    %{
      io_ref: io,
      size: size,
      bin_position: pos
    } = state
    {:ok, size} = RecordLog.insert(io, msg)
    new_pos = calc_position(pos, size)
    %State{state | bin_position: new_pos, size: size + 1}
  end

  defp calc_position({start, stop}, size), do: {start, stop + size}

  @spec update_rels(binary(), map()) :: map()
  defp update_rels(binary_msg, relations) do
    msg = Decoder.decode_message(binary_msg)
    Map.put(relations, msg.id, msg)
  end  

  @spec rotated_log_file(pos_integer()) :: {io_device(), Path.t()}
  defp rotated_log_file(rotated_num) do
    {:ok, cwd} = File.cwd()
    path = "#{cwd}/backlogs/tmp.#{rotated_num}"
    {:ok, io} = RecordLog.recreate(path)
    {io, path}  
  end

  @spec update_rotated_file(io_device(), Path.t(), pos_integer()) :: {{io_device(), Path.t()}, pos_integer()}
  defp update_rotated_file(io, path, num) do
    case File.stat(path) do
      {:ok, stat} ->
        if stat.size > @file_size do
          File.close(io)
          new_num = if num < @max_files, do: num + 1, else: 1
          {rotated_log_file(new_num), new_num}
        else
          {{io, path}, num}
        end
      {:error, reason} -> 
        Logger.error("File.stat in update_rotated_file: #{inspect(reason)}")
        {{io, path}, num}
    end
  end

end
