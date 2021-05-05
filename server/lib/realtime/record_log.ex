defmodule Realtime.RecordLog do
  @type io_device() :: io_device()
  @type posix() :: posix()
  @type decoded() :: {:ok, {io_device(), non_neg_integer(), term()}} | {:error, any()}

  @spec open(String.t()) :: {:ok, io_device()} | {:error, posix()}
  def open(path) when is_binary(path) do
    File.open(path, [:append])
  end

  @spec close(io_device()) :: :ok | {:error, posix() | :badarg | :terminated}
  def close(io) do
    File.close(io)
  end

  @spec remove(String.t()) :: :ok | {:error, posix()}
  def remove(path) when is_binary(path) do
    File.rm(path)
  end

  @spec insert(io_device(), term()) :: :ok | {:error, any()}
  def insert(io, record) do
    bin = :erlang.term_to_binary(record)
    :file.write(io, <<byte_size(bin)::32, bin::binary>>)    
  end

  @spec first(String.t()) :: :ok | {:error, posix()}
  def first(path) when is_binary(path) do
    chars_path = String.to_charlist(path)
    {:ok, io} = :file.open(chars_path, [:read, :raw, :binary])
    record(io, 0)
  end

  def next(io, pos) do
    record(io, pos)
  end

  @spec stream(String.t()) :: {:ok, function()} | {:error, :enoent}
  def stream(path) do
    if File.exists?(path) do
      stream = Stream.resource(
        fn ->
          chars_path = String.to_charlist(path)
          {:ok, io} = :file.open(chars_path, [:read, :raw, :binary])
          {io, 0}
        end,
        fn {io, pos} ->
          case record(io, pos) do
            {:ok, {io, next_pos, record}} ->
              {[record], {io, next_pos}}
            _ -> {:halt, io}
          end
        end,
        fn io -> close(io) end
      )
      {:ok, stream}
    else
      {:error, :enoent}
    end
  end

  @spec record(io_device(), non_neg_integer()) :: :eof | {:error, any} | decoded()
  defp record(io, pos) do
    case :file.pread(io, pos, 4) do
      :eof -> :eof
      {:ok, <<len::32>>} ->
        decode(io, pos + 4, len)
      {:error, reason} -> 
        {:error, reason}
    end
  end

  @spec decode(io_device(), non_neg_integer(), non_neg_integer()) :: decoded()
  defp decode(io, pos, len) do
    {:ok, bin} = :file.pread(io, pos, len)
    try do
      rec = :erlang.binary_to_term(bin)
      {:ok, {io, pos + len, rec}}
    rescue
      _ -> {:error, "unable decode record"}
    end
  end  

end
